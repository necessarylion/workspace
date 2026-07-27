# Workspace

A native macOS app for working across your GitHub and Bitbucket repositories:
see your projects, their open pull requests, review diffs, comment on PRs,
browse and edit files, and drive Claude Code in an embedded terminal.

## Layout

```
┌──────────────┬────────────────────────────────┬──────────────────┐
│           >_ │  ‹ ›  breadcrumb          ✕    │Files│±│>_│✳│Info│
│              ├────────────────────────────────┼──────────────────┤
│ repo card    │                                │ file tree        │
│  branch ↑↓   │  one viewer:                   │ changes          │
│  2 PR clean  │  dashboard · file · diff · PR  │ terminals        │
│              │                                │ claude           │
│              │                                │ ports, open in…  │
│ + Add Repo   ├────────────────────────────────┤                  │
│              │ Ln 12, Col 4  Swift  ⚠2  sourcekit-lsp running    │
└──────────────┴────────────────────────────────┴──────────────────┘
```

- **Left sidebar — Repositories.** One card per repo you added: host, branch,
  ahead/behind, open-PR count, changed-file count, live ports. A **filter box**
  narrows the list by name or path, and cards are **reordered by dragging** them
  onto each other. A card carries **Claude's mark, breathing**, while one of
  that repo's conversations is mid-turn (with a count when more than one), and
  so does its square on the folded rail. Its header row carries the **home
  terminal button** (⇧⌘T) and nothing else. Collapsible (⌘0).
- **Centre — the viewer.** Exactly **one** thing at a time: opening a file
  replaces what is there. Back/forward (⌘[ / ⌘]) walk the history, like a
  browser. Its header row names what is open, and with nothing open the
  **selected repository and its branch**. Not collapsible.
- **Right sidebar — the navigator**, five tabs for the selected repo:
  *Files*, *Changes*, *Terminals*, *Claude*, *Info*. **Which tab you are on is
  kept per repository**, next to that repo's viewer history — reading a file in
  one and watching a terminal in another are two places to be, and switching
  between them lands back where each was left. Collapsible (⌥⌘0).
  The pull requests are not one of them — they are a table on the dashboard,
  which is the only pane wide enough for their columns.

**No scrollbars anywhere.** Every pane, list, diff and the editor scroll by
wheel, trackpad and keyboard as usual, but nothing is drawn over the content and
no strip is reserved for it, whatever the system's "show scroll bars" setting is.

Nothing appears in the app until you add a repository folder yourself.

## Features

| Area | What works |
| --- | --- |
| Repositories | Add any folder; the remote is detected from `origin` (GitHub, Bitbucket Cloud, Bitbucket Data Center, including SSH aliases like `bitbucket-ajzkk`). Remembered between launches. **Drag a card onto another** to reorder the list — the order is saved as you drag, so it survives a relaunch. The **filter box** at the top matches on repo name or folder path; reordering is off while it is filtering, since only part of the list is on screen. |
| GitHub accounts | Logged in to `gh` with more than one account? Adding a GitHub repo asks which one it belongs to, and every later `gh` call for that repo uses it — the choice is remembered between launches and changed from the repo's context menu or the Info tab. Nothing global is switched: each call carries that account's token in `GH_TOKEN`, so your own shell and your other repos are untouched. |
| How the hosts are asked | Everything the app **reads** from Bitbucket goes through `bkt api` — the REST API — rather than through `bkt`'s own `pr` subcommands, which hand on a thinned-out pull request: no reviewers, no comment count, no draft flag, so every column beside a title used to cost a call of its own per request. The API also takes `fields=`, so what comes back can be what is wanted instead of a description nobody asked for. One call now answers the board; one answers a pull request opened by number, reviewers and all; **`/pullrequests/{id}/statuses`** answers the builds where it used to take four calls (a `bkt status pr`, a commit listing to find the head, that commit's statuses, then the repository's pipelines filtered by branch). Every one of these keeps its old `bkt pr …` path underneath, because **Data Center speaks `/rest/api/1.0/` and answers none of them**. Writes — comment, approve, merge, decline, edit — are left on the subcommands: they are one call either way, and the subcommand is the one that works on both flavours. On GitHub the porcelain *is* the batched path: `gh pr list --json` and `gh pr view --json` are single GraphQL calls that fetch reviewers, reviews and check runs together, so moving them to `gh api` would turn one round trip into several. |
| Pull requests | Open PRs per repo via `gh pr list` / `bkt pr list`. The title sits in the window header next to back/forward; a slim bar under it keeps branches, line counts and review state on the left and, on the right, the **three tabs** that pick what fills the window: **Details** (description plus the conversation — existing comments and a box to post a new one, `gh pr comment` / `bkt pr comment`), **Diff** (the whole window, see below) and **Commits** (see below). The Details tab has the pull request's own **side panel** down its right (see below). Opening one **leaves the navigator exactly where you had it** — nothing switches tabs or folds a pane away for you. The source branch carries a **copy** and a **check out** button; checkout runs git in the background (fetching the branch first when it is only on the remote) and reports success or git's own error in a toast. |
| Editing the description | The description is **written here as well as read**: **Edit** at the end of the author row on the Details tab (**Add a description** when there is none yet) turns it into its **Markdown source**, in a monospaced box that stands as tall as what is in it, and **Save** (⌘S) writes it back — `gh pr edit --body` / `bkt pr edit --body`. ⎋ or **Cancel** drops the edit; a host that refuses leaves the box open with your text still in it, so nothing written is lost. What the editor opens on is **what the host stores, not what is on screen**: Bitbucket Cloud writes a mention as an account id and the app shows the name in its place, so the raw text is fetched back before editing — otherwise saving would turn the mention into plain words. Once it lands, the description is redrawn straight away rather than waiting for the PR list to come round again. |
| Mentioning people | Type **`@` in any box that writes a comment** — the conversation's composer, a reply inside a thread, and the box that starts a thread on a line of the diff — and the people you can name appear above it: **face, handle and full name**, ↑↓ to walk them, ⏎ or ⇥ to take one, ⎋ to close the list. It is the same list the reviewer picker uses (contributors and collaborators on GitHub; default reviewers, recent commit authors and workspace members on Bitbucket), ranked so the people closest to this repository come first, **with the pull request's author included** — an `@` names them more often than it names anyone else, and only the reviewer picker leaves them out. What goes into the text is **the name**, on every host — you should be able to read back what you just wrote. Bitbucket Cloud does not accept that: its raw Markdown carries no usernames at all, and notifies nobody unless a mention is an id in braces, `@{712020:297e58ad-…}`. So the id is put on **as the comment is sent** rather than typed into the box, at the one point every comment passes through — only for names the host itself offered, longest first so `@adam` is never read as `@ada` with a stray letter after it, and never where the `@` sits inside a word, which is what keeps an email address out of it. GitHub needs none of this, since there the name and the login are the same string. Once posted, the comment reads back as a name (see the row above). The people are read from the host the first time an `@` is typed and never again, so a comment that names nobody costs nothing. The box is not a text field but a growing one built on `NSTextView`, since a completion list has to be offered the arrow keys before the text is: **⏎ writes a line, ⌘↩ posts**. |
| Comment threads | Replies are shown **nested under the comment they answer**, at any depth, and each one has its own **Reply** box. Every author's name gets a **colour of their own**, derived from the name so it is the same in every thread and every launch. Bitbucket threads every comment; on GitHub only inline review comments thread, so Reply appears on those (`.../comments/{id}/replies`). |
| Pictures and mentions in comments | A **screenshot pasted into a comment or a description is drawn where it was pasted**, at its own size or the pane's, whichever is smaller; clicking it opens the original. Bitbucket hangs its own `{: data-layout='center' }` off such an image — that is swallowed rather than left as braces in the text. A **mention reads as a name**: Bitbucket's raw Markdown writes one as `@{712020:297e58ad-…}`, an account id and nothing else, so the names are read off the HTML Bitbucket renders beside it and put back. A picture the app can reach is drawn; one it cannot becomes a **named placeholder that opens in your browser**. That is what a Bitbucket screenshot does: Bitbucket serves those from `bitbucket.org` rather than from its API, to a browser session and nothing else — no API token opens them, so the app names the file and hands it to the browser you are already signed in to. |
| Inline comments | A comment anchored to a line appears **in the diff, under that line**, with its replies nested. Hover any line and the **+** in the gutter starts a new thread there — in split view the column you click picks the side (before / after the change), in unified view the line does. Works in both layouts and on both hosts. |
| Dashboard | What the centre shows when nothing is open (the repo's name sits in the header row above it): the remote and branch with the **Ask Claude button** at the end of that row, five counters (open PRs, changed files, terminals, ports, files) that jump to the matching navigator tab — **Open PRs** scrolls down to the table instead, since the pull requests are on this page — the **open pull request table** (see below), and — under them — the branch's **recent commits grouped by day** ("Today", "Yesterday", then the date), each day headed with how many commits it holds. A row shows short hash, subject, time and author; **click one to open that commit's diff** in the viewer (`git show`), or right-click to copy its hash or message. A **`#123` in the subject is a link** — blue, underlined as the pointer crosses it — and clicking it opens that pull request in the viewer, merged or closed ones included (`gh pr view` / `bkt pr view`, so the list of open ones is not the limit); the rest of the row still opens the commit. It starts at 8 commits with a **Show N more** button for the rest of the 40 it read, and a **Load 40 older** button that reads a page further back — as many times as the history allows, the button disappearing when there is nothing older left. How deep you went is kept, so the refresh it does every time the dashboard comes back on screen returns the same range, and a commit made in the terminal is there when you switch back. **The whole board reads itself again every time you land on it** — branch and change list, history, ports and pull requests, all at once and none of them blanking what is already drawn — so closing a file and coming back never shows you the board you left. The pull requests are the one part that is held back: they cost a call to GitHub or Bitbucket, so a landing within ten seconds of the last read keeps the table it already has. |
| Open pull request table | The open requests are **a table on the dashboard**, one row each, with a column per question a reviewer actually asks: **Summary**, **Created**, **Activity**, **Reviewers**, **Builds**. This replaced both a grid of tiles and a list of cards in the navigator — a tile reads one request at a time, and the thing being done here is comparing them. The Summary column is three lines: the author's face beside an **OPEN** / **DRAFT** badge and the title, then *who · #number, updated when*, then the source → target branches on a line of their own — sharing one meant the byline and the branches fought for the same points and both lost. Each row is its own **rounded card** inside the box, so the alternating tint and the hover read as *that request* rather than as a bar across the table. **Created** is the age of the request, plainly — how old is too old is not a judgement the list makes for you. **Activity** is the comment count, **Reviewers** up to three faces (worst verdict first, each with its own approve / changes / waiting mark, `+N` for the rest), **Builds** one glyph for the whole CI run — the worst outcome wins, so one red job is never buried under green ones. A column the host said nothing about shows a **dash**, not a zero. Clicking a row opens the request; right-click copies its link or branch; **↻** in the section header reads them again. **Every row is read in one round of calls, not one per request.** GitHub answers for all of it with a single `gh pr list` — reviewers and checks included. Bitbucket Cloud is asked through `bkt api` instead of `bkt pr list`, which thins the payload out: **two calls made at the same time**, `/pullrequests` with `fields=+values.reviewers,+values.participants,+values.comment_count,+values.draft` for the list itself, and `/pipelines` newest-first for the builds — a pipeline run names its request in `target.pullrequest.id`, so one page of runs is a verdict for every request that has one. Only Bitbucket Data Center, and a Cloud repo that reports builds as commit statuses rather than pipelines, still costs a call per request; there the columns fill in **after the board is on screen**, four at a time. |
| Recent commits, in the Changes tab | The branch's **last five commits stand above its uncommitted work** — the order the two are read in: what just went out, then what is going out next. One line each, the hash as a chip at the front and the subject taking the rest; who made it and when are in the tooltip, because a sidebar has no width to spare for them. **Clicking one opens that commit's patch in the centre**, exactly as clicking it on the dashboard does, and the row it is showing stays tinted. Right-click copies the hash or the whole message. The list re-reads itself with the git status, so a commit made here — or in the terminal beside it — is at the top of it straight away. |
| Changes tab | The working tree in two groups, **Staged** and **Changes**, each with a bulk **Stage All** / **Unstage All**; the **+** / **−** on a row moves that one file, and the **↺** next to it discards that file (a **🗑** on an untracked file, which is deleted) after a confirmation. Below them a **commit box**: write a message — or press the **Claude button** next to Commit and have one written for you, from the staged files (or the whole working tree while nothing is staged), in the style of the repository's recent messages — **Commit** (⌘⏎) the staged files, then **Push** — which shows how many commits are waiting (`Push 2`) and sets the upstream itself the first time the branch goes out. Unstaging uses `git restore --staged`, so it never touches your edits. Whatever git prints on a failure is shown in the box. |
| Conflicts | A merge git could not finish gets a **third group above the other two**, one row per unmerged path, named the way git names them — **Both Modified**, **Both Added**, **Added by Us**, **Deleted by Them** and the rest — in red, under a warning triangle. A conflict is deliberately in neither pile: the index holds the three merge stages rather than a resolution, and the **−** the Staged group would have offered runs `git restore --staged`, which throws those stages away and keeps our side without asking. So the row's button is a **✓ Mark Resolved** instead (`git add`, which is what settles it), with **Resolve All** on the group header, and it **refuses while the file still has `<<<<<<<` or `>>>>>>>` in it** — nothing later in the flow catches markers, and they would go straight into the commit. **Stage All** stages everything except the conflicts for the same reason. The **↺** discards that file's merge back to the version the branch had before it, and says so before it does. Clicking a row opens the diff with the markers in it, so the file can be fixed in the editor and then marked. Until the last one is gone the commit box says how many are left and **Commit stays shut**. |
| Commits | The **Commits** tab lists the pull request's commits **grouped by day** — "Today", "Yesterday", then the date, each day headed with how many commits it holds — loaded the first time you open the tab (`gh pr view --json commits`, Bitbucket's REST API through `bkt api`). A row is **the same row the dashboard draws** for the repository's own history: face, short hash, subject, and the hour it landed. What differs is the click: on the dashboard the whole row opens the commit, here **only the hash does** — it is drawn in link blue, and underlines under the pointer, so the one part of the row that goes somewhere says so. Right-click copies the hash or the message. Opening one shows that commit's own diff in the same tab, with the full message above it and a **‹ Commits** button back to the list; the hash can be copied or opened on the host there. A **`#123`** in a subject or in that full message links to the pull request it names, in the list and above the diff alike. The patch comes from a local `git show` when the commit is already in the checkout, and from the host when it is not. |
| PR action bar | A second row under the summary holds what one actually does with a pull request, as buttons rather than menu items: **Approve** and **Request Changes** on the left (`gh pr review --approve` / `--request-changes`; `bkt pr approve` and Bitbucket Cloud's `request-changes` endpoint), then **Update from main** — only when the branch is behind — **Reject** and **Merge** on the right. **Every one of them opens the same confirmation sheet first** — what is about to happen, a box for the comment that goes with it, Cancel (⎋) and a confirm button (⏎) tinted to match. Nothing reaches the host unconfirmed, and "request changes" keeps its button disabled until a comment is written, because GitHub refuses a review without one. The review lands in the conversation and the bar's own review badge updates from the host. |
| Reviewers and approvals | The summary bar carries an **approvals badge** — `2/3`, the people who approved out of the people asked — green once they all have, orange while anyone wants changes. Hovering it names every reviewer and what they said; clicking it opens the **reviewer sheet**. The full list, **face plus verdict per person**, lives in the PR side panel (see below). **Add Reviewers** opens the sheet: it lists who is already on the pull request and what each of them said, then a **suggestion list** of the people who can be asked. There is no single list to ask a host for, so every source that answers is merged and **the ones closest to this repository come first**: on GitHub its contributors, then its collaborators and assignable users, with the bots dropped — so the list is not empty on a repo where you are the only collaborator. On Bitbucket the repository's **default reviewers** and the authors of its **recent commits** lead, then whoever opened or merged its recent pull requests, then the **workspace's members** and, on Data Center, the repository's users and the instance directory. Cloud only names its members when the token carries the `account` scope, which is exactly why the repository-level sources are asked too. Every source is called at once rather than one after another. The line above the rows says which they are: a suggestion while the box is empty, how many matched once you type. Tick as many as you like and they are asked in one call (`gh pr edit --add-reviewer`, `bkt pr edit --reviewer`); somebody already asked stays on the list, greyed out and saying so. The box at the top searches the list **and doubles as a way in**: type a handle that is not on it and it is sent as typed, which is what carries a host that will not say who its members are. The list is read once per pull request, when the sheet is first opened. **The author is never counted** — Bitbucket lists them among the participants, and counting them would make the badge read wrong — and a merged or closed pull request keeps the count it ended on without offering to add anyone. |
| PR side panel | A **second, narrower sidebar down the right of the Details tab** — the two things a reviewer checks before anything else, in a column beside the conversation. **Reviewers**: everyone asked, worst verdict first, each a face with what they said under their name, and an **Add Reviewers** card under the list that opens the reviewer sheet. **Builds**: the CI runs on the head commit — GitHub checks, Bitbucket build statuses and Cloud pipelines, normalised to a name, an outcome, how long it took and a link to the log — failures first, with a **↻** to read them again. They are fetched the first time the panel is on screen. It is **Details only** — the Diff and Commits tabs are read across the whole width — and it **does not collapse**; the seam beside it drags to resize. On the other two tabs the news is still in the summary bar: the **approvals badge** and, next to it, a **builds badge** coloured by the worst run — clicking that badge goes back to Details, where the list is. |
| Merge, reject, sync | The **Merge** button opens a sheet to pick the way: **Squash and Merge** (one commit on the target branch, selected by default) or **Merge (fast-forward)** (the commits as they are, no merge commit) — `gh pr merge --squash` / `--rebase`, `bkt pr merge --strategy`. The sheet warns when the branch is behind, and ⏎ merges the selected way. **Reject** closes it without merging (`gh pr close` / `bkt pr decline`) and takes an optional reason, posted as the closing comment. Each asks first, and none of them deletes the source branch. When the branch has fallen behind, an orange **“N behind main”** badge appears in the summary bar and an **Update from main** button in the action bar — it brings the target branch in: GitHub does it on the server, Bitbucket in your checkout (branch checked out, tree clean → fetch, merge, push). The count comes from `gh api …/compare` on GitHub and from your own refs elsewhere; **Check Again** fetches first. |
| Diffs | `git diff` for working-tree changes (per file or **all changes at once**) and `gh/bkt pr diff` for PRs, rendered **side by side** (default) or unified, with **tree-sitter syntax colours**. A changed line is coloured in **two tiers** — a wash over the whole line, and a stronger block behind the **words that actually differ**, matched token by token, so an edited argument stands out from the rest of the line it sits in. |
| Diff file list | A diff of more than one file gets an **index down its left side**: every file with its icon, folder and `+`/`−` counts. Picking one shows **that file alone** — only its rows are built — and **All Files** at the top of the list goes back to the whole diff. The sidebar button in the diff bar hides the index; the choice of file is remembered per pull request, so leaving the Diff tab and coming back returns to the file being reviewed. |
| Big diffs | Past **10 files** a diff is never built whole: it opens on its **first file and is read one at a time**, each file **syntax-coloured the moment it is opened** rather than all of them up front, the index stays open because it is the only way between them, and **All Files** / **Show All** are gone — there is no whole diff to go back to. For the same reason **View All Changes** is disabled while the working tree has more than 10 changed files. |
| File tree | Every file, **dotfiles included** (`.env`, `.mcp.json`, `.github`) — only `.git`, `.build`, `.swiftpm`, `node_modules` and `DerivedData` are hidden. Anything `.gitignore` covers is **hidden by default** — build output and caches bury the rest — and the **eye button** in the pane's bottom bar brings those rows back, **faded** but there to open. Each row carries the **real logo** of what it is (TypeScript, React, Docker, Postgres, …) in that ecosystem's colour, and repositories show the **GitHub or Bitbucket mark**. |
| Go to file (⌘P) | A **palette on glass over the window**: type a few letters and the **whole repository** is narrowed to them, ⏎ opens the picked file in the editor. It searches the **file names and paths**, which is what the tree cannot do — the tree only reads a folder once you expand it, so a filter over it can only ever see where you have already been. The list comes from `git ls-files`, so nothing `.gitignore` covers is offered, and a folder that is no repository is walked instead. **The punctuation does not have to be typed**: query and path are both folded down — lowercased, with spaces, `_`, `-`, `.` and `/` dropped — so `item controller`, `item_controller`, `ItemController` and `itemcontroller` are one query, and every one of them finds `app/controllers/item_controller.rb`. `views file` crosses the slash the same way. Then ranked by **where** the match landed: a file whose **name** starts with what you typed comes before one that merely carries those letters in a folder name, ties go to the shorter path, and last come the ones matched **letter by letter** — `csv` finds `CodeServiceView.swift`. Wherever the query landed is **picked out in the accent colour**, name and folder alike, with a separator the fold stepped over taken along so `item_controller` highlights in one piece. Before anything is typed it lists the **files you had open**, newest first and the one on screen left out, so **⌘P⏎** is the way back to the file you just left. **↑↓** walk the rows (they wrap), **⎋** closes it, and clicking a row opens it too. |
| Search in files | The box above the tree searches **what is inside the files**, not their names, the way VS Code's search pane does. Results come back **grouped by file** — name, folder and how many lines matched — with **each matching line under it**, the query picked out of the line in the accent colour; clicking a line **opens the file on it** — and in the editor **every occurrence in that file is marked**, not only the line clicked, so a file opened from a search reads as the set of hits it is. The marks follow the text as you edit it and go when the box is emptied. It is literal and case-insensitive until the query itself carries a capital, it runs a beat after you stop typing so a word is one search rather than one per letter, and the **eye button** decides whether what `.gitignore` covers is searched too. **ripgrep** does the work when it is installed — the same tool VS Code searches with — and `git grep` when it is not, so nothing has to be installed for it to work. |
| Managing files | The tree is not read-only. **Drop files on a folder row** and they land in it — from Finder, from another app, or from elsewhere in the tree; **a dropped folder brings everything inside it**, the empty space below the rows drops into the repository root, and holding a drag over a closed folder **springs it open** so you can go further in. A file dragged **from inside the repo moves**, anything from outside is **copied**, and a name already taken is numbered around (`notes 2.md`) so a drop never overwrites. A row's context menu **renames**, **duplicates** and **moves to Trash** — deleting is recoverable in Finder, which is why it does not stop to ask — and a row can be **dragged out** to Finder or any app that takes files. Whatever the change was, the folder re-reads itself with every other folder left open as it was, and git status refreshes so the Changes tab keeps up. **A file that was open stays open**: renaming or moving it puts it back in the viewer at its new path, picked in the tree, and only deleting it closes it. The tree also re-reads itself after **any git command** — staging, unstaging, committing, discarding, checking out a branch — so a file the working tree gained or lost is never left on screen. |
| Picking several files | **⌘-click** adds a row, **⇧-click** takes the range from the last one clicked, and clicking below the rows lets the lot go. Every action then works on the whole selection — the menu says how many (*Duplicate 3 Items*, *Move 3 Items to Trash*) — and **dragging any selected row drags them all** into the folder you drop on. A selected row is filled in the accent colour; the file **open in the viewer** keeps a paler tint of it, so "what I am about to act on" and "what I am looking at" never look the same. |
| Files by keyboard | With the tree focused: **↑ ↓** walk the rows, **⇧↑ ⇧↓** stretch the selection, **⏎ renames in place** — the box opens over the name with the extension left out of the selection, ⏎ again commits it, ⎋ or clicking away leaves it alone — and **⌘⌫** moves what is picked to the Trash. A rename that collides is refused with the reason in a toast rather than quietly numbered, since you typed that name on purpose. |
| One editor at a time | Opening a file **closes the file before it**. The pane has always shown one thing, but every file ever opened used to stay behind it — its whole text, its diagnostics and symbols, its place in the back/forward history — so a morning of clicking through a repository left dozens of documents alive and the app slower for each. **⎋ or the ✕ closes the editor outright.** A file with **unsaved edits is the exception** and keeps its slot until it is saved or closed by hand: nothing else in the app would warn about the edits, so dropping it would be losing work silently. Only files are treated this way — a shell has something running behind it, and a diff or a pull request costs a title and a patch rather than a live editor. |
| Editor | Our own: `NSTextView` + **tree-sitter** highlighting + **LSP**. Gutter with line numbers and diagnostic markers, caret-line highlight, auto-indent, bracket matching, soft wrap toggle. A file the editing stack cannot take on in full — over **1 MB**, or carrying a **line longer than 5,000 characters**, which a minified bundle like `mermaid.min.js` is both of — opens **read-only** instead: wrapped, numbered, and plain, with **no highlighting, no language server and no search marks**, and the status bar says why. Everything skipped there is something that walks or lays out the whole document at once, which is what used to take the window down rather than merely slow it. |
| Markdown preview | A `.md` file opens as **rendered Markdown** rather than source: headings, lists, task lists, quotes, tables and inline code chips. A fenced code block is **coloured by the editor's own tree-sitter highlighter** in the theme you picked in Settings — the fence's language word (` ```swift `, ` ```ts `, ` ```sh `) stands in for the file name the editor would have detected it from, and a fence naming nothing we have a grammar for stays plain. A ` ```mermaid ` fence is **drawn as a diagram** — flowcharts, sequence and the rest — by mermaid itself, which ships **inside the app**, so a diagram draws the same offline and on every Mac. It takes the pane's own colours, scales to the width, and a fence mermaid cannot parse falls back to its text with the complaint above it. |
| Markdown as PDF | While the preview is up, the **⤓ in the header row** (or *Editor ▸ Save as PDF…*, ⇧⌘E) writes the document out as a **PDF**: the rendered page, not the source, with the **mermaid diagrams drawn into it**. It is a light document — made to be printed and mailed rather than read in a dark viewer — laid out on your own paper size, and links stay clickable. Pages are cut where nothing is crossing: between blocks, and between the lines of a paragraph or code block too long to fit a sheet, so a line of text is never sliced in half. Nothing is fetched to do it and no other tool has to be installed. |
| draw.io preview | A `.drawio` file opens **as the diagram**, not as its XML — drawn by draw.io's own viewer, which ships **inside the app**, so it works offline and needs nothing installed. The diagram is fitted to the pane and drawn dark like everything else; **⌘-scroll or pinch** zooms, a **drag** pans once it is bigger than the pane, and a toolbar fades in over it with the **pages of a multi-page file**, zoom and layers. The **eye** in the header row (or *Editor ▸ Draw Diagrams*) switches to the XML behind it, which is the ordinary editor. `.dio` files count, as do the `.xml`, `.svg` and `.html` files draw.io exports with the model kept inside — those are recognised by the `<mxfile>` in them, not by their name. Diagrams built from the extra stencil libraries (AWS, Azure and the like) draw everything but those shapes: they live on draw.io's servers and nothing here goes to the network. |
| PDF preview | A `.pdf` file opens **as the document**, drawn by PDFKit: continuous scrolling, pinch to zoom and text selection you can copy out of, without leaving the window. A floating bar at the bottom edge steps through the pages, shows **which page of how many** is on screen, and zooms in, out, or back to fitting the window. The 4 MB limit that guards the text editor does not apply, because a PDF is read page by page rather than loaded whole. |
| Language servers | Started per language and project root, warmed up as soon as a repository is selected: diagnostics (squiggles + gutter dots + hover), completions (⌃Space), hover help, and ⌘-click go-to-definition. See the table below. |
| Info tab | Folder path, remote, GitHub account, branch, head commit, **listening ports** for processes started inside the folder (right-click one to open it, copy its URL, or **stop the process** holding it), running language servers, and one-click **Open in** VS Code / Cursor / Sublime / Zed / Finder / Terminal. |
| Ask Claude | A **Claude Code conversation in a terminal tab**, started by the **Ask Claude button** at the top of the dashboard, by **New Conversation** in the Claude tab, or by ⇧⌘L. It is the real CLI in the real terminal — the app types `claude` at a shell rooted in the repo and gets out of the way. **The getting-there is covered**: from the moment the tab appears until `claude` is up, the pane is a spinner reading *Starting Claude Code…* rather than a shell prompt, the flags being decided and a command typing itself in — and the shell is left unfocused for exactly that long, so a keystroke cannot land in the line the app is about to type at. The cover comes down when the shell announces the program it started, or on a timer if your shell renames nothing; the Claude tab's row says *starting…* meanwhile, for a conversation you opened and then looked away from. **This used to be a pane of its own**: one `claude -p --input-format stream-json` per repo, whose every message, tool call and diff the app parsed and redrew in SwiftUI. It looked the part and cost far more than the thing it was imitating — a long conversation was thousands of live views the window carried whether or not you were looking at it — so it is gone. What replaced it is faster, and every version of Claude Code works in it, flags, slash commands, plugins and all, without the app knowing about any of them. **As many can run at once as you start**: each is its own shell and its own process, so a turn working away in one carries on while you type into another, and none of them stops because you looked at something else. A new conversation is given its id up front (`--session-id`), which is what lets the list tell a conversation that is *running* from the transcript it is writing — a CLI too old for that flag simply goes without. |
| Find in file | **⌘F** puts a find bar in the editor's top corner. Typing marks **every** occurrence in the file — the same marks the file search leaves, so the machinery is shared rather than doubled — and the bar counts them; **⏎ jumps to the next one**, selects it, centres it and flashes the system's find bubble on it, wrapping round the end of the file. The **⌃ ⌄** buttons walk both ways and the count reads `3 of 17`. **⎋ closes the bar** and hands the keyboard back to the text — and while the bar is up ⎋ belongs to it, not to the file, so a search can never close what you were reading. Editing while the bar is open keeps the marks under the right words: they slide with the edit and the file is re-scanned once the typing stops. |
| Claude tab | The conversations this repo has **running** in this window, then every conversation Claude Code has ever had about it, newest first. A running one is a terminal tab: click its row and that shell comes back on screen, and the **✕ under the pointer** ends that one alone. **A running conversation is called what it is about, not "Claude Code"** — the name is the first thing asked in it, read back from the same transcript the history below is titled from, so one conversation reads the same whether it is running or over. It appears once that first prompt has landed; until then the shell's own tab name stands in, and the terminal's header row shows the same name. A row that is **mid-turn says *working…*** rather than *running*, which is the same thing the repository's card is badged with — with several conversations open it is the only way to tell which one is still going. **A conversation is listed here and nowhere else** — it runs in a terminal tab, but the Terminals tab leaves it out, so the shells you opened yourself are not buried among chats and there is one way back to each. The **PAST** heading is a switch — click it and the whole history folds away, with the number of hidden conversations beside it — and the choice is **remembered between launches**. The history is read from `~/.claude/projects/…`, so **a session you started in a shell of your own is in the list too**, titled by the first thing you asked and stamped with when it last moved. **Click one and it resumes in a terminal of its own** (`claude --resume`), leaving whatever else is running alone; clicking it again comes back to that same tab rather than starting a second `claude` on the same transcript. Nothing is launched by looking: the list costs no `claude` process. **New Conversation** sits at the top, and the **✕** on a past row (or *Move to Trash*) throws it away — transcript and the folder of tool output beside it, to the Trash rather than unlinked, so it does not stop to ask. |
| Terminal | Embedded **libghostty** (the [Ghostty](https://github.com/ghostty-org/ghostty) engine) rooted at the repo, **any number of shells** per repo, switched from the Terminals tab rather than a tab bar in the viewer. Your own Ghostty theme/font config applies. Used for Claude Code runs. **Drop a file on it** and its path is typed at the prompt — several files land side by side, spaces and brackets escaped — which is how a screenshot or a log reaches `claude`. An image dragged straight out of a browser or Preview carries no file, so it is saved as a PNG in the temporary folder and *that* path is typed. |
| Home terminals | Shells that belong to **no repository**, rooted in your home folder (⇧⌘T). They sit in the same list as the rest, listed under *Home*, and they outlive removing every repository — so there is a prompt before a single folder has been added. |
| Terminals button | A **terminal glyph with a count** in the centre header, from anywhere in the app: a new shell in *Home* or in the selected repo, then every open shell, newest first, to jump straight back to one. It needs no repository and no sidebar, which is what makes the home shells always reachable. |
| Terminals tab | Every shell that is still open, across all repos, **in the order they were started** — showing one never moves its card, so the list stays where your eye left it. A shell **keeps running until you close its tab** — leaving the terminal, opening a file or switching repo never kills it, and "Open Terminal" returns to the one you had. **Claude Code conversations are not in this list**: they run in terminal tabs of the same repo, but the Claude tab is where they are listed, so "Open Terminal" comes back to a shell rather than to a chat, and the numbering counts shells alone. |
| Saved terminals | The list **survives quitting the app**: every tab's folder, name and order is kept (in `UserDefaults`), and comes back on the next launch. A restored tab is listed dimmed and **starts its shell the moment you show it**, so relaunching never spawns ten processes at once. Tabs whose repo was removed, or whose folder has moved, are dropped. |
| Notifications | A **Notification Centre banner when a shell wants you back**, so a conversation left working while you are in an editor or a browser can say so. Three things raise one, all of them from the terminal itself: `claude` **ringing the bell** (which is how it asks for a permission decision mid-turn), a **desktop notification the program asked for** (OSC 9 / OSC 777), and **a turn ending**. That last one needs no configuration at all — Claude Code marks its own tab title, `⠂ …` while a turn runs and `✳ …` when it is over, so the spinner going away *is* the turn finishing. The banner is titled with the conversation and subtitled with the repository, and **clicking it brings that exact tab back on screen** and the app to the front. Nothing is posted for the shell you are already looking at, and two in the same three seconds collapse into one. There is **no switch for it in Settings**: macOS already has one per app in System Settings ▸ Notifications, and a second one that could disagree with it is a support question waiting to happen. The permission is asked for the first time you open a terminal, never at launch. |
| Settings (⌘,) → Appearance | The **theme and the font code is shown in**. Four themes ship with the app — **Adonis Eclipse**, **GitHub Dark**, **Atom One Dark** and **Dark+** — each a full palette for the editor and the diff, including the background, gutter, current line and indent guides, with a row of swatches under the picker so two dark themes can be told apart at a glance. They travel with the app, so a file looks the same on every Mac you run it on. `Scripts/import-vscode-theme.swift "Some Theme"` ports any VS Code theme into a new one — it reads the extension's own theme file and translates its TextMate scopes into the tree-sitter captures our highlighter produces. Then the fonts: One face for the editor and the diff, each with its own size (a diff is denser on purpose), **line spacing** for the editor, and the terminal left to your own Ghostty config until you switch it over. Only **monospaced faces** are listed — Fira Code, JetBrains Mono, Monaspace and the rest are found even though those families leave the `monoSpace` trait unset — and each is drawn in itself in the menu. Every change applies at once: the editor re-lays out, and libghostty is handed a new configuration, so **shells already running** change font too. Kept in `UserDefaults`; **Restore Defaults** puts back SF Mono at 12.5 / 10 pt and ×1.0 spacing. |
| Settings (⌘,) → Requirements | The **command line tools** the app drives — `git`, `gh`, `bkt`, `claude`, `rg` — each with its own `--version` line and who it is signed in as, all asked of the tool itself through your login shell. Missing one? **Install** runs the right command (`brew install gh`, `brew install ripgrep`, …); logged out? **Sign In** runs `gh auth login` / `bkt auth login`. Both are interactive, so they run in a real terminal inside the sheet rather than silently in the background. Installing **ripgrep** takes effect at once — the file search notices without a relaunch. The gear in the repositories footer carries a **dot** when a tool your repos actually need is missing or logged out; a missing `claude` or `rg` never raises it, since neither stops anything from working. |
| Settings (⌘,) → Language Servers | Every server the editor can start, with a **ready / not installed** badge checked against the same PATH the editor uses. **Install** runs that server's own line (`brew install rust-analyzer`, `npm install -g pyright`, …) in a terminal. **Add** gives any other language a server — pick the language, then type the executable, the command, the LSP language ID and, if you like, an install command. Any built-in can be **edited**, **restored** to its default, or removed; changes are kept in `UserDefaults` and take effect the next time a file of that language is opened. |
| Settings (⌘,) → Updates | **The app updates itself from its own GitHub releases.** Every six hours it asks `api.github.com` for the latest release — plain HTTPS, no `gh`, no account, nothing to install, because a release asset is a public URL — and compares the tag against the version `Scripts/bundle.sh` stamped into the bundle. A newer one is **downloaded and unpacked in the background**; then it stops, and a notice in the window's corner offers the **Relaunch** that finishes it, since restarting closes whatever you were in the middle of. The swap itself is a script that waits for the app to quit, sets the old bundle aside with a rename, `ditto`s the new one into its place — putting the old one back if that fails — and opens the result. Both halves are switches: check automatically, and download automatically. **Check for Updates…** in the app menu asks straight away, and while an update is waiting the sidebar keeps a badge next to the gear. A copy running from a disk image or from Xcode's build folder is never overwritten behind your back. |

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

## Requirements

- macOS 14+, Xcode 16+ toolchain
- [`gh`](https://cli.github.com) authenticated, for GitHub pull requests
- [`bkt`](https://github.com/avivsinai/bitbucket-cli) configured, for Bitbucket
- `claude` on your PATH, for the Claude Code actions
- [`rg`](https://github.com/BurntSushi/ripgrep) (ripgrep), for searching inside
  files — optional, `git grep` stands in when it is missing

**Settings (⌘,) checks all of these for you** and installs or signs in to the
missing ones — you never have to work out which command it wanted. Its
**Updates** tab is where the app keeps itself current, which needs none of them.

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
Anyway** in Privacy & Security. The disk image changes nothing here: the
warning is about the app, not its container, and only notarization removes it,
which needs a paid Apple Developer account. An **update installed from inside
the app** is the one way round it: nothing marks a file the app downloaded
itself as coming from the internet, and the swap clears the flag anyway — so
the warning is a first-install thing, not something every version costs.

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
| ⌘, | Settings — code font, required tools and language servers, install and sign-in, and the app's own updates |
| ⇧⌘O | Add repository |
| ⌘S | Save the file you are editing · save the PR description you are editing |
| ⇧⌘E | Save the Markdown preview as a PDF |
| ⇧⌘W | Close what is open (a terminal only goes back to the dashboard) |
| ⎋ | The same, the editor included — except **while the terminal has the keyboard**, where ⎋ goes to the program in it (`claude` reads it to interrupt a turn, clear the line, and twice over to open the history); use ⌃` or ⇧⌘W to leave a terminal. A completion list and a comment box you are writing in keep ⎋ too |
| ⌘[ / ⌘] | Back / forward through history |
| ⌘P | Go to file — the whole repository by name, ↑↓ to walk it, ⏎ to open, ⎋ to leave (⌘P again closes it too) |
| ⌘0 / ⌥⌘0 | Toggle the repositories / navigator sidebar |
| ⌃⇥ | Switch repository — hold ⌃ and the repos appear in a row on glass, ⇥ walks it (⇧⇥ back), letting go of ⌃ switches |
| ⌘R | Refresh all repositories |
| ⇧⌘L | Ask Claude — start a conversation about the selected repo, in a terminal tab |
| ⌃⌘T | Open (or return to) the terminal of the selected repo |
| ⌃` | Show the selected repo's terminal, and the same key to leave it |
| ⌘T | New terminal tab |
| ⇧⌘T | New terminal in your home folder (no repo needed) |
| ⌃⌘P | Create PR with Claude Code |
| ⌃Space | Completions |
| ⌘-click | Go to definition · in the file tree, add a row to the selection |
| ⌘↩ | Post the PR comment you typed · commit the staged files |
| @ | In any PR comment box: the people you can name, ↑↓ to walk them, ⏎ or ⇥ to take one, ⎋ to close the list |
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
  Support/SettingsWindow.swift  opening ⌘, from a menu item, on a chosen tab
  Models/
    RemoteInfo.swift          origin URL → GitHub/Bitbucket + owner/slug
    Project.swift             one repository: remote, status, PRs, ports, tree
    PullRequest.swift         unified PR model + gh/bkt loaders
    PullRequestComment.swift  reading and posting PR comments
    PullRequestCommit.swift   a PR's commits + the diff of one commit
    PullRequestActions.swift  merge, reject, and drift from the target branch
    PullRequestReviewer.swift  who is reviewing, their verdicts, and asking more people
    PullRequestBuild.swift    the CI runs on the head commit, normalised across hosts
    GitHubAccounts.swift      per-repo gh account choice + GH_TOKEN injection
    GitStatus.swift           porcelain status + per-file diff
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
    AppearanceSettings.swift  the theme and the code font: face, sizes, spacing
    AppUpdater.swift          the app's own releases: check, download, swap, relaunch
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
    ClaudeSessionListView.swift  conversations running and on disk, in the navigator
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
    ProjectSwitcherOverlay.swift  ⌃⇥ — the repositories in a row, on glass
    FileFinderOverlay.swift   ⌘P — find a file by name, on glass
    SettingsView.swift        ⌘, — Appearance, Requirements, Language Servers, Updates
    UpdateSettings.swift      the Updates tab, and the corner notice a new version leaves
    ToolConsoleSheet.swift    runs one install or sign-in in a real terminal
```

## Not done yet

- Creating a PR from a form inside the app (today: Claude Code or the web UI).
- Re-running a failed build from the side panel (today: the link to the host).
