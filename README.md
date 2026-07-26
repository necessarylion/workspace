# Workspace

A native macOS app for working across your GitHub and Bitbucket repositories:
see your projects, their open pull requests, review diffs, comment on PRs,
browse and edit files, and drive Claude Code in an embedded terminal.

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
  *Files*, *PRs*, *Changes*, *Terminals*, *Claude*, *Info*. Collapsible (⌥⌘0).

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
| Pictures and mentions in comments | A **screenshot pasted into a comment or a description is drawn where it was pasted**, at its own size or the pane's, whichever is smaller; clicking it opens the original. Bitbucket hangs its own `{: data-layout='center' }` off such an image — that is swallowed rather than left as braces in the text. A **mention reads as a name**: Bitbucket's raw Markdown writes one as `@{712020:297e58ad-…}`, an account id and nothing else, so the names are read off the HTML Bitbucket renders beside it and put back. A picture the app can reach is drawn; one it cannot becomes a **named placeholder that opens in your browser**. That is what a Bitbucket screenshot does: Bitbucket serves those from `bitbucket.org` rather than from its API, to a browser session and nothing else — no API token opens them, so the app names the file and hands it to the browser you are already signed in to. |
| Inline comments | A comment anchored to a line appears **in the diff, under that line**, with its replies nested. Hover any line and the **+** in the gutter starts a new thread there — in split view the column you click picks the side (before / after the change), in unified view the line does. Works in both layouts and on both hosts. |
| Dashboard | What the centre shows when nothing is open (the repo's name sits in the header row above it): the remote and branch with the **Ask Claude button** at the end of that row, five counters (open PRs, changed files, terminals, ports, files) that jump to the matching navigator tab, a tile per open pull request, and — under them — the branch's **recent commits grouped by day** ("Today", "Yesterday", then the date), each day headed with how many commits it holds. A row shows short hash, subject, time and author; **click one to open that commit's diff** in the viewer (`git show`), or right-click to copy its hash or message. A **`#123` in the subject is a link** — blue, underlined as the pointer crosses it — and clicking it opens that pull request in the viewer, merged or closed ones included (`gh pr view` / `bkt pr view`, so the list of open ones is not the limit); the rest of the row still opens the commit. It starts at 8 commits with a **Show N more** button for the rest of the 40 it read, and a **Load 40 older** button that reads a page further back — as many times as the history allows, the button disappearing when there is nothing older left. How deep you went is kept, so the refresh it does every time the dashboard comes back on screen returns the same range, and a commit made in the terminal is there when you switch back. |
| Changes tab | The working tree in two groups, **Staged** and **Changes**, each with a bulk **Stage All** / **Unstage All**; the **+** / **−** on a row moves that one file, and the **↺** next to it discards that file (a **🗑** on an untracked file, which is deleted) after a confirmation. Below them a **commit box**: write a message — or press the **Claude button** next to Commit and have one written for you, from the staged files (or the whole working tree while nothing is staged), in the style of the repository's recent messages — **Commit** (⌘⏎) the staged files, then **Push** — which shows how many commits are waiting (`Push 2`) and sets the upstream itself the first time the branch goes out. Unstaging uses `git restore --staged`, so it never touches your edits. Whatever git prints on a failure is shown in the box. |
| Commits | The **Commits** tab lists the pull request's commits newest first — short hash, subject, author and when — loaded the first time you open the tab (`gh pr view --json commits`, Bitbucket's REST API through `bkt api`). **Click one** and it opens that commit's own diff in the same tab, with the full message above it and a **‹ Commits** button back to the list; the hash can be copied or opened on the host. A **`#123`** in a subject or in that full message links to the pull request it names, in the list and above the diff alike. The patch comes from a local `git show` when the commit is already in the checkout, and from the host when it is not. |
| PR action bar | A second row under the summary holds what one actually does with a pull request, as buttons rather than menu items: **Approve** and **Request Changes** on the left (`gh pr review --approve` / `--request-changes`; `bkt pr approve` and Bitbucket Cloud's `request-changes` endpoint), then **Update from main** — only when the branch is behind — **Reject** and **Merge** on the right. **Every one of them opens the same confirmation sheet first** — what is about to happen, a box for the comment that goes with it, Cancel (⎋) and a confirm button (⏎) tinted to match. Nothing reaches the host unconfirmed, and "request changes" keeps its button disabled until a comment is written, because GitHub refuses a review without one. The review lands in the conversation and the bar's own review badge updates from the host. |
| Merge, reject, sync | The **Merge** button opens a sheet to pick the way: **Squash and Merge** (one commit on the target branch, selected by default) or **Merge (fast-forward)** (the commits as they are, no merge commit) — `gh pr merge --squash` / `--rebase`, `bkt pr merge --strategy`. The sheet warns when the branch is behind, and ⏎ merges the selected way. **Reject** closes it without merging (`gh pr close` / `bkt pr decline`) and takes an optional reason, posted as the closing comment. Each asks first, and none of them deletes the source branch. When the branch has fallen behind, an orange **“N behind main”** badge appears in the summary bar and an **Update from main** button in the action bar — it brings the target branch in: GitHub does it on the server, Bitbucket in your checkout (branch checked out, tree clean → fetch, merge, push). The count comes from `gh api …/compare` on GitHub and from your own refs elsewhere; **Check Again** fetches first. |
| Diffs | `git diff` for working-tree changes (per file or **all changes at once**) and `gh/bkt pr diff` for PRs, rendered **side by side** (default) or unified, with **tree-sitter syntax colours**. A changed line is coloured in **two tiers** — a wash over the whole line, and a stronger block behind the **words that actually differ**, matched token by token, so an edited argument stands out from the rest of the line it sits in. |
| Diff file list | A diff of more than one file gets an **index down its left side**: every file with its icon, folder and `+`/`−` counts. Picking one shows **that file alone** — only its rows are built — and **All Files** at the top of the list goes back to the whole diff. The sidebar button in the diff bar hides the index; the choice of file is remembered per pull request, so leaving the Diff tab and coming back returns to the file being reviewed. |
| Big diffs | Past **20 files** a diff is never built whole: it opens on its **first file and is read one at a time**, each file **syntax-coloured the moment it is opened** rather than all of them up front, the index stays open because it is the only way between them, and **All Files** / **Show All** are gone — there is no whole diff to go back to. For the same reason **View All Changes** is disabled while the working tree has more than 20 changed files. |
| File tree | Every file, **dotfiles included** (`.env`, `.mcp.json`, `.github`) — only `.git`, `.build`, `.swiftpm`, `node_modules` and `DerivedData` are hidden. Anything `.gitignore` covers is **hidden by default** — build output and caches bury the rest — and the **eye button** in the pane's bottom bar brings those rows back, **faded** but there to open. Each row carries the **real logo** of what it is (TypeScript, React, Docker, Postgres, …) in that ecosystem's colour, and repositories show the **GitHub or Bitbucket mark**. |
| Go to file (⌘P) | A **palette on glass over the window**: type a few letters and the **whole repository** is narrowed to them, ⏎ opens the picked file in the editor. It searches the **file names and paths**, which is what the tree cannot do — the tree only reads a folder once you expand it, so a filter over it can only ever see where you have already been. The list comes from `git ls-files`, so nothing `.gitignore` covers is offered, and a folder that is no repository is walked instead. **The punctuation does not have to be typed**: query and path are both folded down — lowercased, with spaces, `_`, `-`, `.` and `/` dropped — so `item controller`, `item_controller`, `ItemController` and `itemcontroller` are one query, and every one of them finds `app/controllers/item_controller.rb`. `views file` crosses the slash the same way. Then ranked by **where** the match landed: a file whose **name** starts with what you typed comes before one that merely carries those letters in a folder name, ties go to the shorter path, and last come the ones matched **letter by letter** — `csv` finds `CodeServiceView.swift`. Wherever the query landed is **picked out in the accent colour**, name and folder alike, with a separator the fold stepped over taken along so `item_controller` highlights in one piece. Before anything is typed it lists the **files you had open**, newest first and the one on screen left out, so **⌘P⏎** is the way back to the file you just left. **↑↓** walk the rows (they wrap), **⎋** closes it, and clicking a row opens it too. |
| Search in files | The box above the tree searches **what is inside the files**, not their names, the way VS Code's search pane does. Results come back **grouped by file** — name, folder and how many lines matched — with **each matching line under it**, the query picked out of the line in the accent colour; clicking a line **opens the file on it** — and in the editor **every occurrence in that file is marked**, not only the line clicked, so a file opened from a search reads as the set of hits it is. The marks follow the text as you edit it and go when the box is emptied. It is literal and case-insensitive until the query itself carries a capital, it runs a beat after you stop typing so a word is one search rather than one per letter, and the **eye button** decides whether what `.gitignore` covers is searched too. **ripgrep** does the work when it is installed — the same tool VS Code searches with — and `git grep` when it is not, so nothing has to be installed for it to work. |
| Managing files | The tree is not read-only. **Drop files on a folder row** and they land in it — from Finder, from another app, or from elsewhere in the tree; **a dropped folder brings everything inside it**, the empty space below the rows drops into the repository root, and holding a drag over a closed folder **springs it open** so you can go further in. A file dragged **from inside the repo moves**, anything from outside is **copied**, and a name already taken is numbered around (`notes 2.md`) so a drop never overwrites. A row's context menu **renames**, **duplicates** and **moves to Trash** — deleting is recoverable in Finder, which is why it does not stop to ask — and a row can be **dragged out** to Finder or any app that takes files. Whatever the change was, the folder re-reads itself with every other folder left open as it was, and git status refreshes so the Changes tab keeps up. **A file that was open stays open**: renaming or moving it puts it back in the viewer at its new path, picked in the tree, and only deleting it closes it. The tree also re-reads itself after **any git command** — staging, unstaging, committing, discarding, checking out a branch — so a file the working tree gained or lost is never left on screen. |
| Picking several files | **⌘-click** adds a row, **⇧-click** takes the range from the last one clicked, and clicking below the rows lets the lot go. Every action then works on the whole selection — the menu says how many (*Duplicate 3 Items*, *Move 3 Items to Trash*) — and **dragging any selected row drags them all** into the folder you drop on. A selected row is filled in the accent colour; the file **open in the viewer** keeps a paler tint of it, so "what I am about to act on" and "what I am looking at" never look the same. |
| Files by keyboard | With the tree focused: **↑ ↓** walk the rows, **⇧↑ ⇧↓** stretch the selection, **⏎ renames in place** — the box opens over the name with the extension left out of the selection, ⏎ again commits it, ⎋ or clicking away leaves it alone — and **⌘⌫** moves what is picked to the Trash. A rename that collides is refused with the reason in a toast rather than quietly numbered, since you typed that name on purpose. |
| Editor | Our own: `NSTextView` + **tree-sitter** highlighting + **LSP**. Gutter with line numbers and diagnostic markers, caret-line highlight, auto-indent, bracket matching, soft wrap toggle. |
| Markdown preview | A `.md` file opens as **rendered Markdown** rather than source: headings, lists, task lists, quotes, tables and inline code chips. A fenced code block is **coloured by the editor's own tree-sitter highlighter** in the theme you picked in Settings — the fence's language word (` ```swift `, ` ```ts `, ` ```sh `) stands in for the file name the editor would have detected it from, and a fence naming nothing we have a grammar for stays plain. A ` ```mermaid ` fence is **drawn as a diagram** — flowcharts, sequence and the rest — by mermaid itself, which ships **inside the app**, so a diagram draws the same offline and on every Mac. It takes the pane's own colours, scales to the width, and a fence mermaid cannot parse falls back to its text with the complaint above it. |
| Markdown as PDF | While the preview is up, the **⤓ in the header row** (or *Editor ▸ Save as PDF…*, ⇧⌘E) writes the document out as a **PDF**: the rendered page, not the source, with the **mermaid diagrams drawn into it**. It is a light document — made to be printed and mailed rather than read in a dark viewer — laid out on your own paper size, and links stay clickable. Pages are cut where nothing is crossing: between blocks, and between the lines of a paragraph or code block too long to fit a sheet, so a line of text is never sliced in half. Nothing is fetched to do it and no other tool has to be installed. |
| draw.io preview | A `.drawio` file opens **as the diagram**, not as its XML — drawn by draw.io's own viewer, which ships **inside the app**, so it works offline and needs nothing installed. The diagram is fitted to the pane and drawn dark like everything else; **⌘-scroll or pinch** zooms, a **drag** pans once it is bigger than the pane, and a toolbar fades in over it with the **pages of a multi-page file**, zoom and layers. The **eye** in the header row (or *Editor ▸ Draw Diagrams*) switches to the XML behind it, which is the ordinary editor. `.dio` files count, as do the `.xml`, `.svg` and `.html` files draw.io exports with the model kept inside — those are recognised by the `<mxfile>` in them, not by their name. Diagrams built from the extra stencil libraries (AWS, Azure and the like) draw everything but those shapes: they live on draw.io's servers and nothing here goes to the network. |
| PDF preview | A `.pdf` file opens **as the document**, drawn by PDFKit: continuous scrolling, pinch to zoom and text selection you can copy out of, without leaving the window. A floating bar at the bottom edge steps through the pages, shows **which page of how many** is on screen, and zooms in, out, or back to fitting the window. The 4 MB limit that guards the text editor does not apply, because a PDF is read page by page rather than loaded whole. |
| Language servers | Started lazily per language and project root: diagnostics (squiggles + gutter dots + hover), completions (⌃Space), hover help, and ⌘-click go-to-definition. See the table below. |
| Info tab | Folder path, remote, GitHub account, branch, head commit, **listening ports** for processes started inside the folder (right-click one to open it, copy its URL, or **stop the process** holding it), running language servers, and one-click **Open in** VS Code / Cursor / Sublime / Zed / Finder / Terminal. |
| Ask Claude | A **chat with Claude Code in the centre pane**, opened by the **Ask Claude button** at the top of the dashboard (or ⇧⌘L) — the same `claude` the terminal runs, driven rather than typed at, so the answer is a conversation instead of terminal output. One process per repo stays up for the whole chat (`claude -p --input-format stream-json --output-format stream-json`), rooted in the repo folder, so Claude reads and edits the files in it and runs commands there. Text arrives **as it is written**; **thinking** is folded away behind one line; every **tool call is its own row** — the glyph, the tool, and the command or file it was given — that unfolds into what it was passed and what came back, with a button to **open the file it touched** in the editor next door. The box is **one line tall and grows** with what you write. **⏎ sends, ⇧⏎ starts a new line**, ⎋ closes the chat and leaves it running. You can **send a follow-up while Claude is still working**: it goes down the pipe at once and is picked up **in the middle of the turn** — steering what it is already doing rather than waiting in line behind it. **Stop** ends only the turn it is on, and a prompt sent just before it still runs. Type **`/`** at the start of a message for the **slash commands** — the repo's own `.claude/commands` (nested ones namespaced, `frontend/build.md` → `/frontend:build`) with their frontmatter descriptions, your `~/.claude/commands`, and the built-ins: **`/mcp`, `/usage`, `/context`, `/model`, `/effort`, `/compact`, `/init`, `/review`, `/security-review`** are offered from the first `/`, each checked against the real CLI to be sure it answers for real in this mode. Plugin and skill commands join them from what the CLI reports in its `init`, which is also remembered between launches — and that report replaces the defaults, so a command your version does not have stops being offered. `/clear` is deliberately left out: it would empty the CLI's memory while the transcript on screen still showed the conversation, and the two would quietly disagree from then on — *New Conversation* is the honest way to do that here. Type **`@`** anywhere for the **files**, the whole repo and not just what the tree has loaded (`git ls-files`, so nothing `.gitignore` covers), ranked by where the match lands — a file whose *name* starts with what you typed comes before one that merely has those letters in a folder name. ↑ ↓ walk the list, ⏎ or ⇥ takes one, ⎋ closes it. Under the box: **+** opens the file panel and what you pick goes in front of the prompt as `@path` mentions, then three switchers — **model** (Default, Opus, Sonnet, Haiku, Fable), **mode** (Auto, Plan, Accept Edits, Full Access) and **effort** (Default through Max). Those are flags on the process, so changing one **restarts it with `--resume`** — the conversation carries on where it was, nothing is lost. Which `claude` runs is settled by asking an *interactive* shell where it is, so a Homebrew copy on a login shell's PATH cannot shadow the one you actually use; what that particular version accepts is read from its own `--help`, so a switcher never offers a flag it would refuse to start with. The conversation and the half-written prompt **survive leaving the chat**, like a terminal does. Claude is told it is answering in a chat window (`--append-system-prompt`): a `-p` session has no interactive question tool and `--tools` will not put one back, so left alone it announces that before every question — *"There is no interactive question tool available in this session, so here it is as plain text."* Now it just asks, options as a numbered list you can answer by number — and when a reply **ends in a question with numbered options**, those options are drawn as **buttons under it**: click one and it goes straight back as your answer, or joins what you were already typing rather than overwriting it. Deliberately hard to trigger, so a reply that merely ends in a list does not sprout buttons: the numbering has to run 1, 2, 3 in order, the list has to be the last thing in the reply, and the line above it has to end in a question mark — or in a colon that is visibly asking you to choose, since "Here's what I changed:" is followed by a numbered list in half the replies ever written. |
| Claude tab | Every conversation Claude Code has had about this repo, newest first, in the navigator — opened with the chat. They are read from `~/.claude/projects/…`, so **a session you started in a shell is in the list too**, titled by the first thing you asked and stamped with when it last moved. Click one and it comes back on screen — the transcript is replayed off disk and the next prompt goes out with `--resume`, so you are carrying on rather than starting again. Nothing is launched by looking: opening an old conversation to read it costs no `claude` process. **New Conversation** sits at the top of the list, and the **✕ under the pointer** (or *Move to Trash*) throws one away — transcript and the folder of tool output beside it, to the Trash rather than unlinked, so it does not stop to ask. |
| Terminal | Embedded **libghostty** (the [Ghostty](https://github.com/ghostty-org/ghostty) engine) rooted at the repo, **any number of shells** per repo, switched from the Terminals tab rather than a tab bar in the viewer. Your own Ghostty theme/font config applies. Used for Claude Code runs. **Drop a file on it** and its path is typed at the prompt — several files land side by side, spaces and brackets escaped — which is how a screenshot or a log reaches `claude`. An image dragged straight out of a browser or Preview carries no file, so it is saved as a PNG in the temporary folder and *that* path is typed. |
| Home terminals | Shells that belong to **no repository**, rooted in your home folder (⇧⌘T). They sit in the same list as the rest, listed under *Home*, and they outlive removing every repository — so there is a prompt before a single folder has been added. |
| Terminals button | A **terminal glyph with a count** in the centre header, from anywhere in the app: a new shell in *Home* or in the selected repo, then every open shell, newest first, to jump straight back to one. It needs no repository and no sidebar, which is what makes the home shells always reachable. |
| Terminals tab | Every shell that is still open, across all repos, **in the order they were started** — showing one never moves its card, so the list stays where your eye left it. A shell **keeps running until you close its tab** — leaving the terminal, opening a file or switching repo never kills it, and "Open Terminal" returns to the one you had. |
| Saved terminals | The list **survives quitting the app**: every tab's folder, name and order is kept (in `UserDefaults`), and comes back on the next launch. A restored tab is listed dimmed and **starts its shell the moment you show it**, so relaunching never spawns ten processes at once. Tabs whose repo was removed, or whose folder has moved, are dropped. |
| Settings (⌘,) → Appearance | The **theme and the font code is shown in**. Four themes ship with the app — **Adonis Eclipse**, **GitHub Dark**, **Atom One Dark** and **Dark+** — each a full palette for the editor and the diff, including the background, gutter, current line and indent guides, with a row of swatches under the picker so two dark themes can be told apart at a glance. They travel with the app, so a file looks the same on every Mac you run it on. `Scripts/import-vscode-theme.swift "Some Theme"` ports any VS Code theme into a new one — it reads the extension's own theme file and translates its TextMate scopes into the tree-sitter captures our highlighter produces. Then the fonts: One face for the editor and the diff, each with its own size (a diff is denser on purpose), **line spacing** for the editor, and the terminal left to your own Ghostty config until you switch it over. Only **monospaced faces** are listed — Fira Code, JetBrains Mono, Monaspace and the rest are found even though those families leave the `monoSpace` trait unset — and each is drawn in itself in the menu. Every change applies at once: the editor re-lays out, and libghostty is handed a new configuration, so **shells already running** change font too. Kept in `UserDefaults`; **Restore Defaults** puts back SF Mono at 12.5 / 10 pt and ×1.0 spacing. |
| Settings (⌘,) → Requirements | The **command line tools** the app drives — `git`, `gh`, `bkt`, `claude`, `rg` — each with its own `--version` line and who it is signed in as, all asked of the tool itself through your login shell. Missing one? **Install** runs the right command (`brew install gh`, `brew install ripgrep`, …); logged out? **Sign In** runs `gh auth login` / `bkt auth login`. Both are interactive, so they run in a real terminal inside the sheet rather than silently in the background. Installing **ripgrep** takes effect at once — the file search notices without a relaunch. The gear in the repositories footer carries a **dot** when a tool your repos actually need is missing or logged out; a missing `claude` or `rg` never raises it, since neither stops anything from working. |
| Settings (⌘,) → Language Servers | Every server the editor can start, with a **ready / not installed** badge checked against the same PATH the editor uses. **Install** runs that server's own line (`brew install rust-analyzer`, `npm install -g pyright`, …) in a terminal. **Add** gives any other language a server — pick the language, then type the executable, the command, the LSP language ID and, if you like, an install command. Any built-in can be **edited**, **restored** to its default, or removed; changes are kept in `UserDefaults` and take effect the next time a file of that language is opened. |

### Language servers

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
| Ruby, PHP, Dart, Lua, Kotlin | `solargraph`, `intelephense`, `dart`, `lua-language-server`, `kotlin-language-server` |
| JSON, YAML, HTML, CSS, Bash | the matching `vscode-*-language-server` / `yaml-language-server` / `bash-language-server` |

That table is only the default list: **Settings → Language Servers** installs the
missing ones, corrects a command, and adds a server for any language that is not
here. The Info tab shows which ones are running.

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

## Requirements

- macOS 14+, Xcode 16+ toolchain
- [`gh`](https://cli.github.com) authenticated, for GitHub pull requests
- [`bkt`](https://github.com/avivsinai/bitbucket-cli) configured, for Bitbucket
- `claude` on your PATH, for the Claude Code actions
- [`rg`](https://github.com/BurntSushi/ripgrep) (ripgrep), for searching inside
  files — optional, `git grep` stands in when it is missing

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

### Release

A push to `main` or a pull request only compiles the app — nothing is kept.
Publishing is a version tag:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

CI then builds the universal app and attaches `Workspace.dmg` and
`Workspace.zip` to a release of that name, giving them a permanent download
URL. Making the release through GitHub's web interface instead works the same
way; the workflow finds the release already there and only uploads to it —
though it leaves the notes alone, so the install instructions below are only
written for a release the workflow created itself.

The bundle is signed ad-hoc, not with a Developer ID, so macOS refuses it on
first launch — *Apple could not verify "Workspace" is free of malware*. The
release notes tell people to clear the download flag once with
`xattr -dr com.apple.quarantine /Applications/Workspace.app`, or to use **Open
Anyway** in Privacy & Security. The disk image changes nothing here: the
warning is about the app, not its container, and only notarization removes it,
which needs a paid Apple Developer account.

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
| ⇧⌘E | Save the Markdown preview as a PDF |
| ⇧⌘W | Close what is open (a terminal only goes back to the dashboard) |
| ⎋ | The same, the editor and the terminal included — except with a completion list up, or while writing in a comment box, which keep ⎋ |
| ⌘[ / ⌘] | Back / forward through history |
| ⌘P | Go to file — the whole repository by name, ↑↓ to walk it, ⏎ to open, ⎋ to leave (⌘P again closes it too) |
| ⌘0 / ⌥⌘0 | Toggle the repositories / navigator sidebar |
| ⌃⇥ | Switch repository — hold ⌃ and the repos appear in a row on glass, ⇥ walks it (⇧⇥ back), letting go of ⌃ switches |
| ⌘R | Refresh all repositories |
| ⇧⌘L | Ask Claude — open (or return to) the selected repo's conversation |
| ⏎ / ⇧⏎ | Claude chat: send the prompt (even while it is answering) / start a new line |
| ⌃⌘T | Open (or return to) the terminal of the selected repo |
| ⌃` | Show the selected repo's terminal, and the same key to leave it |
| ⌘T | New terminal tab |
| ⇧⌘T | New terminal in your home folder (no repo needed) |
| ⌃⌘P | Create PR with Claude Code |
| ⌃Space | Completions |
| ⌘-click | Go to definition · in the file tree, add a row to the selection |
| ⌘↩ | Post the PR comment you typed · commit the staged files |
| ↑ ↓ / ⇧↑ ⇧↓ | File tree: walk the rows · stretch the selection |
| ⏎ | File tree: rename the picked row in place (⏎ again to keep it, ⎋ to drop it) |
| ⌘⌫ | File tree: move what is picked to the Trash |
| ⇧-click | File tree: take everything from the last row clicked to this one |

## Layout of the source

```
Sources/Workspace/
  WorkspaceApp.swift          app + menu commands
  Support/Shell.swift         runs git/gh/bkt through the login shell
  Support/GitDirectoryWatcher.swift  git run outside the app: watches `.git` for a checkout
  Support/BrandMark.swift     real logos (TypeScript, Docker, GitHub…) from SVG
  Support/BrandPath.swift     the path data behind them — generated, don't edit
  Support/AuthorAvatar.swift  author pictures: where to find one, cache, disc view
  Support/WindowKeyMonitor.swift  keys the terminal would otherwise eat (⌃⇥, ⎋)
  Support/EscapeKey.swift     ⎋ = close, and who keeps ⎋ for themselves
  Support/PullRequestReference.swift  finding a `#123` written in a commit message
  Support/FileOperations.swift  what the Files tab does to disk: copy, move, rename, trash
  Support/MarkdownPDF.swift   the preview as a PDF: measure, render, cut into sheets
  Support/MarkdownHTML.swift  the same document as a printable page, diagrams and all
  Support/StreamingShellProcess.swift  a command that stays up, read a line at a time
  Support/JSONValue.swift     JSON of a shape only known at runtime (tool inputs)
  Support/RemoteImage.swift   pictures Markdown points at: download once, draw, fall back
  Support/BitbucketMarkup.swift  naming the people a Bitbucket comment only refers to by id
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
    MarkdownCodeHighlighter.swift  tree-sitter colours for a ``` fence
    InlineDiff.swift          which words in a changed line actually changed
    ProjectPorts.swift        lsof → ports owned by this folder
    FileNode.swift            lazy file tree
    OpenDocument.swift        a file being viewed/edited
    ViewerItem.swift          what the viewer shows: file | diff | commit | PR | terminal | chat
    TerminalSession.swift     a live shell (libghostty), started on first show
    ClaudeChat.swift          what a conversation is made of + the three switchers
    ClaudeSession.swift       one `claude` process, driven over stream-json
    ClaudeCLI.swift           which claude this Mac has, and which flags it takes
    ClaudeCommitMessage.swift the commit message, written by a one-shot `claude -p`
    ClaudeSessionsIndex.swift past conversations on disk, and reading one back
    FileSearch.swift          searching inside the files: ripgrep, then git grep
    FileFinder.swift          ⌘P: ranking the repo's paths, and where the query hit
    ClaudeCompletions.swift   the /commands and @files the composer offers
    ClaudeQuickReplies.swift  a question's numbered options, read back as buttons
    ToolRequirements.swift    git/gh/bkt/claude/rg: installed? signed in as whom?
    LanguageServerCatalog.swift  the language server list: defaults + yours
    AppearanceSettings.swift  the theme and the code font: face, sizes, spacing
    WorkspaceStore.swift      window state + back/forward history + saved terminals
  Editor/
    CodeEditorController.swift  wires text view, gutter, tree-sitter and LSP
    CodeTextView.swift          NSTextView with code-editing habits
    LineNumberRuler.swift       gutter: numbers + diagnostic markers
    TreeSitterHighlighter.swift incremental parsing and capture ranges
    LanguageDetection.swift     file name → grammar, incl. the `.env` family
    SyntaxTheme.swift           fonts + the palette in use
    HoverInfoWindow.swift       floating hover / diagnostic panel
    CodeEditorView.swift        SwiftUI bridge
  LSP/
    LSPTypes.swift              the protocol subset we speak
    LSPConnection.swift         JSON-RPC over stdio
    LanguageService.swift       one server: handshake, sync, requests
    LanguageServerRegistry.swift  catalog → running server, one per project root
    LanguageServerOptions.swift   initializationOptions, for the servers needing them
  Themes/
    SyntaxPalette.swift       capture name → colour, and the lookup behind it
    Themes.swift              the list Settings shows; first one is the default
    AdonisEclipse.swift       one theme, one file
    GitHubDark.swift          github.com's own dark
    AtomOneDark.swift         the One Dark everyone ported
    DarkPlus.swift            VS Code's default dark, and ours
  Resources/                  checked in, so nothing is fetched at runtime
    mermaid.min.js            mermaid, and the page it draws a fence in
    mermaid-host.html
    drawio-viewer.min.js      draw.io's viewer, and the page it draws a file in
    drawio-host.html
  Views/                      projects sidebar, navigator, viewer, diff, PR, info
    ClaudeChatView.swift      the chat: transcript, tool rows, composer, switchers
    ClaudeSessionListView.swift  past conversations, in the navigator
    ChatInputField.swift      the prompt box: one line, growing, ⏎ sends
    ChatCompletionList.swift  the / and @ list, and reading the token under the caret
    MarkdownPreview.swift     the Markdown renderer: blocks, tables, code chips
    DiagramWebView.swift      the web view both diagram renderers are driven in
    MermaidDiagramView.swift  a ```mermaid fence, drawn in the Markdown column
    DrawioPreview.swift       a .drawio file, drawn in the whole pane
    PDFPreviewView.swift      a .pdf file, drawn by PDFKit, with a page bar
    CommitMessageText.swift   a commit message with its #123 drawn as a link
    ProjectSwitcherOverlay.swift  ⌃⇥ — the repositories in a row, on glass
    FileFinderOverlay.swift   ⌘P — find a file by name, on glass
    SettingsView.swift        ⌘, — Appearance, Requirements and Language Servers
    ToolConsoleSheet.swift    runs one install or sign-in in a real terminal
```

## Not done yet

- Pipeline builds: the PR's **Builds** tab is a placeholder; nothing is read from
  `gh pr checks` or Bitbucket pipelines yet.
- Creating a PR from a form inside the app (today: Claude Code or the web UI).
- PR approvals and merge actions (comments do work).
