# Development

How the project is built, released, and laid out. The user-facing README is in
the repository root; this is the part that only matters if you are changing the
code.

## Build and run

```sh
Scripts/run.sh          # build, wrap in Workspace.app, launch
Scripts/bundle.sh       # build + bundle only, prints the .app path
Scripts/install.sh      # build Release and install to /Applications
Scripts/make-icon.sh    # rebuild Resources/AppIcon.icns from Assets/icon.png
```

Both build scripts take an optional configuration (`Scripts/bundle.sh Release`).
Or open `Package.swift` in Xcode and run.

> `swift build` does **not** work: a dependency ships an asset catalog, which
> only `xcodebuild` can compile. Both scripts use `xcodebuild` and set
> `DISABLE_SWIFTLINT=1`, because CodeEditLanguages' SwiftLint build plugin fails
> on Xcode 26.

`Release` builds a universal arm64 + x86_64 binary; `Debug` builds only for this
machine, so the edit-run loop stays fast. `UNIVERSAL=1` forces both in Debug.

## Dependencies

A bare clone builds with nothing installed beyond Xcode — that is what CI
(`.github/workflows/build.yml`) relies on. Where the two big pieces come from:

- **Tree-sitter grammars** — `CodeEditLanguages` is checked in under
  [Vendor/](../Vendor/) and referenced by path. Its upstream repository keeps
  every historical revision of every grammar, so cloning it costs ~600 MB against
  34 MB for the release source; see [Vendor/README.md](../Vendor/README.md).
- **The terminal engine** — comes from
  [libghostty-spm](https://github.com/Lakr233/libghostty-spm), which ships
  libghostty as a prebuilt, checksum-pinned universal xcframework. Upstream
  ghostty publishes no equivalent artifact; see [Terminal.md](Terminal.md).
  Ghostty's runtime resources live in `Resources/ghostty-share/` and are checked
  in — they are not part of the xcframework, and the terminal needs them.

## Release

A push to `main` or a pull request only compiles the app — nothing is kept.
Publishing is a version tag:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

CI then builds the universal app and attaches `Workspace.dmg` and
`Workspace.zip` to a release of that name, giving them a permanent download
URL. Making the release through GitHub's web interface instead works the same
way; the workflow finds the release already there and only uploads to it —
though it leaves the notes alone, so the install instructions are only written
for a release the workflow created itself.

The tag is also the app's **version**. `Scripts/bundle.sh` stamps
`CFBundleShortVersionString` from it — CI passes the tag it is building, a local
build takes the newest tag it can see, and a tree with no tags at all gets
`0.0.0`, which no release can match, so a development build always reads the
latest release as newer than itself. That number is the whole of what the
in-app updater compares, so **a release whose tag is older than, or equal to,
what people are running does nothing** — the version has to go up.

Updating happens **inside the app** from there on: it reads
`api.github.com/repos/…/releases/latest` over HTTPS, takes the `Workspace.zip`
attached to it, unpacks it with `ditto` and swaps the bundle. Nothing about that
path needs `gh` or a sign-in, but it does need the **repository to be public** —
the API answers a private repository the same way it answers one with no
releases, and the app reports it as "no published release found".

The bundle is signed ad-hoc, not with a Developer ID, so macOS refuses it on
first launch — *Apple could not verify "Workspace" is free of malware*. The
release notes tell people to clear the download flag once with
`xattr -dr com.apple.quarantine /Applications/Workspace.app`, or to use **Open
Anyway** in Privacy & Security. The disk image changes nothing here: the warning
is about the app, not its container, and only notarization removes it, which
needs a paid Apple Developer account. An **update installed from inside the app**
is the one way round it: nothing marks a file the app downloaded itself as coming
from the internet, and the swap clears the flag anyway — so the warning is a
first-install thing, not something every version costs.

## Language servers

Nothing is bundled — a server is used if it is on your `PATH`.

| Language | Server |
| --- | --- |
| Swift | `sourcekit-lsp` (ships with Xcode) |
| TypeScript / JS / TSX / JSX (React) | `typescript-language-server` |
| Vue | `vue-language-server` (`@vue/language-server@2`, **not 3** — see below), plus a TypeScript 5.x in the project |
| Python | `pyright-langserver` |
| Go | `gopls` |
| Rust | `rust-analyzer` |
| C / C++ / Objective-C | `clangd` |
| Ruby, PHP, Dart, Lua, Kotlin | `ruby-lsp`, `intelephense`, `dart`, `lua-language-server`, `kotlin-lsp` (JetBrains') |
| JSON, YAML, HTML, CSS, Bash | the matching `vscode-*-language-server` / `yaml-language-server` / `bash-language-server` |

That table is only the default list: **Settings → Language Servers** installs the
missing ones, corrects a command, and adds a server for any language that is not
here. The Info tab shows which ones are running.

Missing servers are **downloaded by the app**, the way Zed does it: into
`~/Library/Application Support/Workspace/LanguageServers/`, never into Homebrew,
your global npm packages or your gems, and that folder goes on the front of the
`PATH` the server is launched with. You are asked once, the first time a
repository wants one; **Settings → Language Servers** has the switch and a
**Remove Downloaded** button. Only the npm-published servers are fetched this
way — the ones that arrive with a toolchain (`sourcekit-lsp`, `clangd`, `dart`)
or as a platform binary (`rust-analyzer`, `kotlin-lsp`, `ruby-lsp`) keep their
Install button.

Servers are **started while the dashboard is on screen**, not when a file is
opened. Selecting a repository lists its files, works out which languages are
actually in it, and starts up to six of those servers — the ones covering the
most files — so the first file opened already has completions and diagnostics
instead of waiting on a handshake. Anything past those six still starts on
demand.

A **Vue single-file component** has no grammar of its own — the tree-sitter
grammars arrive as a prebuilt binary that has no Vue in it — so it is parsed as
HTML, and its `<script>` and `<style>` bodies are then coloured by the grammar
they are actually written in: `lang="ts"` gets TypeScript, a bare `<script>`
JavaScript, `<style lang="scss">` the CSS grammar. A grammar normally stops at
its own boundary and hands HTML one flat `raw_text` token, which is what left a
whole script in the plain text colour; each block is parsed separately instead
and its colours shifted into place, cached against the block's text so only
editing inside one re-parses it. Ordinary `.html` files get the same treatment.

**Vue is pinned to `@vue/language-server@2` deliberately.** From 3.0 the server
answers nothing by itself: every request — hover, completion, even the first
lookup of which project a file belongs to — is forwarded to a `tsserver` that the
*editor* is expected to be running alongside it with `@vue/typescript-plugin`
loaded, over `tsserver/request` notifications outside the protocol. There is no
switch to turn that off, so under an editor that runs no such process the server
simply never replies. 2.x still has the switch, and the app throws it
(`vue.hybridMode: false`), which puts the server back in charge of its own
TypeScript project. That project needs a TypeScript to load: the app looks for
`node_modules/typescript` beside the repo and up from it, then for a global one,
and says so in the status bar when there is none. It has to be **5.x** — the 7.x
package is the Go rewrite and ships none of the API the server calls.

See [LSP.md](LSP.md) for how the protocol layer itself is put together.

## Layout of the source

```
Sources/Workspace/
  WorkspaceApp.swift          app + menu commands
  Support/Shell.swift         runs git/gh/bkt through the login shell
  Support/GitDirectoryWatcher.swift  git run outside the app: watches `.git` for a checkout
  Support/WorkingTreeWatcher.swift  files written outside the app: FSEvents over the whole tree
  Support/BrandMark.swift     real logos (TypeScript, Docker, GitHub…) from SVG
  Support/BrandPath.swift     the path data behind them — generated, don't edit
  Support/AuthorAvatar.swift  author pictures: where to find one, cache, disc view
  Support/WindowKeyMonitor.swift  keys the terminal would otherwise eat (⌃⇥, ⎋)
  Support/EscapeKey.swift     ⎋ = close, and who keeps ⎋ for themselves
  Support/PullRequestReference.swift  finding a `#123` written in a commit message
  Support/FileOperations.swift  what the Files tab does to disk: create, copy, move, rename, trash
  Support/MarkdownPDF.swift   the preview as a PDF: measure, render, cut into sheets
  Support/MarkdownHTML.swift  the same document as a printable page, diagrams and all
  Support/MarkdownHTMLText.swift  the HTML in a comment: `<details>`, `<br>`, `&amp;`, hidden comments
  Support/StreamingShellProcess.swift  a command that stays up, read a line at a time
  Support/JSONValue.swift     JSON of a shape only known at runtime (tool inputs)
  Support/RemoteImage.swift   pictures Markdown points at: download once, draw, fall back
  Support/BitbucketMarkup.swift  naming the people a Bitbucket comment only refers to by id
  Support/SettingsWindow.swift  opening ⌘, from a menu item, on a chosen tab
  Models/
    RemoteInfo.swift          origin URL → GitHub/Bitbucket + owner/slug
    NewRepository.swift       making one instead of finding one: `git init`, `git clone`
    Project.swift             one repository: remote, status, PRs, ports, tree
    PullRequest.swift         unified PR model + gh/bkt loaders
    PullRequestComment.swift  reading and posting PR comments
    PullRequestCommit.swift   a PR's commits + the diff of one commit
    PullRequestActions.swift  merge, reject, and drift from the target branch
    PullRequestReviewer.swift  who is reviewing, their verdicts, and asking more people
    PullRequestBuild.swift    the CI runs on the head commit, normalised across hosts
    GitHubAccounts.swift      per-repo gh account choice + GH_TOKEN injection
    GitStatus.swift           porcelain status + per-file diff
    DefaultBranch.swift       which branch the host calls default: gh/bkt, then origin/HEAD
    RepositoryCommit.swift    the branch's own git log, grouped by day
    DiffModel.swift           unified diff → side-by-side rows
    MarkdownCodeHighlighter.swift  tree-sitter colours for a ``` fence
    InlineDiff.swift          which words in a changed line actually changed
    ProjectPorts.swift        lsof → ports owned by this folder
    FileNode.swift            lazy file tree
    OpenDocument.swift        a file being viewed/edited
    ViewerItem.swift          what the viewer shows: file | diff | commit | PR | terminal
    TerminalSession.swift     a live shell (libghostty), started on first show
    TerminalNotifier.swift    Notification Centre banners for a shell that wants you back
    ClaudeCLI.swift           which claude this Mac has, and which flags it takes
    ClaudeCommitMessage.swift the commit message, written by a one-shot `claude -p`
    ClaudeSessionsIndex.swift past conversations on disk: title, date, delete
    FileSearch.swift          searching inside the files: ripgrep, then git grep
    FileFinder.swift          ⌘P: listing the repo's paths, ranking them, where the query hit
    ToolRequirements.swift    git/gh/bkt/claude/rg: installed? signed in as whom?
    LanguageServerCatalog.swift  the language server list: defaults + yours
    AppearanceSettings.swift  the theme and the code font (terminal included): face, sizes, spacing
    KeyboardShortcuts.swift   every key the app binds, its default, and what you rebound it to
    AppUpdater.swift          the app's own releases: check, download, swap, relaunch
    WorkspaceStore.swift      window state, back/forward history, the five-minute refresh
  Editor/
    CodeEditorView.swift        the editor pane: CodeEditSourceEditor + the app's joins
    LanguageServerCoordinator.swift  one open file ↔ its server: sync, diagnostics, ⌘-click, completions
    GutterDiffMarkers.swift     the stripe beside the line numbers: added, changed, deleted
    GitLineStatus.swift         `git diff` for one file, reduced to a marker per line
    EditorThemeBridge.swift     our 56-capture palette → the package's 16 fields
    TreeSitterHighlighter.swift incremental parsing, for the diff and markdown snippets
    LanguageDetection.swift     file name → grammar, incl. the `.env` family
    SyntaxTheme.swift           fonts + the palette in use
  LSP/                          see Docs/LSP.md
    LSPTypes.swift              the protocol subset we speak
    LSPConnection.swift         JSON-RPC over stdio
    LanguageService.swift       one server: handshake, sync, requests
    LanguageServerRegistry.swift  catalog → running server, one per project root
    LanguageServerOptions.swift   initializationOptions, for the servers needing them
  Themes/
    SyntaxPalette.swift       capture name → colour, and the lookup behind it
    TerminalPalette.swift     the same theme as sixteen ANSI slots, for ghostty
    Themes.swift              the list Settings shows; first one is the default
    AdonisEclipse.swift       one theme, one file
    CodeEditTheme.swift       CodeEdit's own default dark
    GitHubDark.swift          github.com's own dark
    AtomOneDark.swift         the One Dark everyone ported
    DarkPlus.swift            VS Code's default dark, and ours
  Resources/                  checked in, so nothing is fetched at runtime
    mermaid.min.js            mermaid, and the page it draws a fence in
    mermaid-host.html
    drawio-viewer.min.js      draw.io's viewer, and the page it draws a file in
    drawio-host.html
  Views/                      projects sidebar, navigator, viewer, diff, PR, info
    ClaudeSessionListView.swift  conversations running (on screen or hidden) and on disk
    ChatPanelOverlay.swift    the floating chats, and the dock they fold down to: one scrolling row of bars, dragged to reorder
    ChatPanelView.swift       one floating chat: title bar, the terminal in it, drag, resize, and the fold that crops it away without unmounting it
    ChatInputField.swift      the growing text box the comment boxes are built on
    ChatCompletionList.swift  the @ list, and reading the token under the caret
    MentionTextBox.swift      a comment box where @ names a person on the pull request
    MarkdownPreview.swift     the Markdown renderer: blocks, tables, code chips
    DiagramWebView.swift      the web view both diagram renderers are driven in
    MermaidDiagramView.swift  a ```mermaid fence, drawn in the Markdown column
    DrawioPreview.swift       a .drawio file, drawn in the whole pane
    PDFPreviewView.swift      a .pdf file, drawn by PDFKit, with a page bar
    PullRequestSidebar.swift  the PR's right-hand panel: reviewers and builds
    PullRequestTable.swift    the open PRs on the dashboard, a row each
    CommitMessageText.swift   a commit message with its #123 drawn as a link
    NewRepositorySheet.swift  ⌘N / ⇧⌘N — an empty repository, or a clone, and the + menu
    ProjectSwitcherOverlay.swift  ⌃⇥ — the repositories in a row, on glass
    FileFinderOverlay.swift   ⌘P — find a file by name, on glass
    SettingsView.swift        ⌘, — Appearance, Shortcuts, Requirements, Language Servers, Updates
    ShortcutSettings.swift    the Shortcuts tab: one recorder per command, conflicts named
    UpdateSettings.swift      the Updates tab, and the corner notice a new version leaves
    ToolConsoleSheet.swift    runs one install or sign-in in a real terminal
```

## Not done yet

- Creating a PR from a form inside the app (today: Claude Code or the web UI).
- Re-running a failed build from the side panel (today: the link to the host).
