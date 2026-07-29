[x] Resolved comments should be collapse and show resolved status
[x] Resolve / unresolve button on a comment thread in PR detail
[x] When PR detail is opened, build status should be refresh in every 10s
[x] Full refresh button in PR details. and instead of copy PR link in tile, replace with open in browser.

## Still missing in PR details

Roughly in order of how much each one hurts. Everything below was checked
against `PullRequestDetailView.swift`, `PullRequestSidebar.swift` and the
`PullRequest*` models — none of it exists yet, on either host.

[ ] Mergeable / conflict state. Nothing reads `mergeable` or
    `mergeStateStatus`, so Merge is always offered at full strength and a
    conflict is only discovered when the host refuses. The sync badge answers a
    different question ("behind the target"), not "will this merge".
[ ] Delete a comment. Reply, edit and resolve are all there; delete is not, so
    a mistyped comment has to be finished on the web.
[ ] Edit the title. The description has a full Markdown editor, but the title —
    the thing every list shows — can only be changed in the browser.
[ ] Draft ↔ Ready for review. `pr.isDraft` is drawn as a badge and never
    toggled, so marking a PR ready needs the host.
[ ] Delete the source branch on merge. The merge sheet says outright "nothing is
    deleted"; there is no option to, which is the normal end of a merge.
[ ] Remove a reviewer, and re-request a review. `addReviewers` is the only
    write; somebody added by mistake stays, and a stale approval cannot be
    asked for again.
[ ] Labels. Not in the model, not in the sidebar, not editable — and on most
    repos they are how a PR is triaged.
[ ] Assignees. Same: `PullRequestReviewer.swift` only mentions the GitHub
    assignees endpoint as a source of *candidates*, never as a field to show or
    set.
[ ] Reactions on comments (👍/🎉/…). Both hosts have them; nothing here reads
    or posts one, so a comment can only be answered with another comment.
[ ] Linked issues ("Closes #123"). Not parsed, not shown, and not opened —
    unlike `#123` in a commit message, which already navigates.
[ ] Per-file "viewed" checkbox in the diff. `DiffFileList` selects a file but
    keeps no read/unread state, so a long review loses its place on every
    reload.
[ ] Suggested changes (` ```suggestion ` blocks) with an Apply button. They
    render as plain fenced code today.
[ ] Reopen a closed PR. The reject sheet says it "can be reopened on GitHub" —
    which is exactly where you have to go to do it. Once `state != .open` the
    whole action bar disappears.
[ ] Unresolved-thread count in the summary bar. It says "N comments"; what a
    reviewer actually wants before merging is how many threads are still open.
[ ] Change the target branch. Fixed at whatever the PR was opened against.

## Still missing in Markdown preview

Checked against `Views/MarkdownPreview.swift` (the block parser and renderer)
and `Support/MarkdownHTMLText.swift`. Everything here affects `.md` files, PR
descriptions and comments alike — they all go through `MarkdownText`.

[ ] Checklists don't work properly. Four separate things:
    - **Not clickable.** `.task` draws a plain `Image(systemName:)`, so a box
      can be read but never ticked — a TODO.md or a PR checklist has to be
      edited by hand, or on the host.
    - **Nested checklists lose their indent.** `.bullet` and `.numbered` both
      carry `indent:`; `.task` does not (`MarkdownPreview.swift:173`), so
      `  - [ ] sub` is drawn flush left, level with its parent.
    - **A box with no text after it is not a box.** The test is
      `rest.hasPrefix("[ ] ")` (line 837), so a bare `- [ ]` falls through to a
      bullet and shows the literal brackets.
    - **Ordered checklists are not recognised.** `1. [ ] thing` goes to
      `orderedItem` and prints `[ ]` as text.
[ ] Hard-wrapped paragraphs come apart. Every source line becomes its own
    `.paragraph` block (line 847), and the stack puts 8pt between blocks — so a
    paragraph wrapped at 80 columns is drawn as a loose ladder of lines instead
    of one flowing block. This is the biggest visual gap for real `.md` files.
[ ] Multi-line list items, same cause: a continuation line under a bullet
    becomes a paragraph of its own and loses both the indent and the bullet.
[ ] Indented code blocks (four spaces). Only ``` fences are recognised, so
    older READMEs render their code as ordinary prose.
[ ] Setext headings. `Title` over `=====` or `-----` — the `---` is matched as
    a horizontal rule first (line 827), so it comes out paragraph + rule.
[ ] Horizontal rules only match `---` and `***` exactly. `___`, `----` and
    `- - -` are all valid and all render as text.
[ ] Bare URLs are not links. Both hosts autolink `https://…` written on its
    own; here only `[text](url)` and `<url>` become links. (Inferred from what
    `AttributedString(markdown:)` does — worth a quick check before fixing.)
[ ] Reference-style links. `[text][ref]` with `[ref]: https://…` further down:
    the link stays literal and the definition line renders as a paragraph.
[ ] Footnotes (`[^1]`). Not parsed at all.
[ ] Table alignment. The `|:---:|` row is dropped (line 747) and every cell is
    leading-aligned, so numeric columns cannot be right-aligned.
[ ] HTML tables. `MarkdownHTMLText` knows `<details>` and `<blockquote>` as
    containers and nothing else, so a bot's `<table>` collapses into a run of
    text with its structure gone.
[ ] Emoji shortcodes (`:tada:`, `:warning:`). Both hosts render them; here they
    stay as the colon-name.
[ ] `#123` and `@name` are not links in rendered Markdown. `CommitMessageText`
    already navigates `#123` in a commit subject — a PR description and a
    comment, where they are far more common, do not.
[ ] A code fence or a nested list inside a list item is hoisted out of it. The
    parser is line-by-line with no block nesting below quotes and `<details>`.
[ ] Copy button on a code block. Everything is selectable, but a fenced block
    is the one thing people copy whole.
[ ] Images cannot be opened. They are capped at 420pt tall and there is no
    click-to-zoom, so a wide screenshot in a PR description can only be
    squinted at.
[ ] No outline for long documents. Headings are drawn but not anchored, so a
    big README has no way to jump around it.

## Missing elsewhere in the app

A sweep over the rest — git, the PR board, the editor and its language servers,
search, shortcuts. Same rule as above: each line was checked against the code,
not against the README.

### Git

[ ] No branch switcher. Only two branches can ever be checked out: the
    repository's default (the dashboard button) and a PR's source branch. There
    is no list of local or remote branches, and no create, rename or delete.
    `git for-each-ref` appears exactly once, in `DefaultBranch.swift:114`, and
    only to guess which branch is the default.
[ ] No stash. Nothing to park half-done work on — which compounds the one
    above, since switching branches is what stashing is usually for.
[ ] No blame. No way to ask who wrote a line, or why.
[ ] No history for a single file. The dashboard lists the repository's recent
    commits; there is no log for the file you are reading.
[ ] No amend, revert or cherry-pick. Commit and push are there, so fixing the
    commit you just made means dropping to the terminal.
[ ] No tags. Not listed, not created — so nothing in the app says what shipped.
[ ] No diff between two arbitrary refs. A PR's diff and a commit's patch are
    the only two; `main...my-branch` cannot be asked for.
[ ] No submodule awareness at all.

### The PR board

[ ] **You cannot create a pull request.** Read, review, comment, approve, merge
    and reject are all there; opening one is not. The README's shortcut table
    lists ⌃⌘P "Create PR with Claude Code" and nothing in the code implements
    it — there is no such `ShortcutAction` case and no handler.
[ ] The board has no filter or search. `PullRequestTable.swift` sorts and never
    filters — no by-author, no "needs my review", no title search.
[ ] No cross-repo review inbox. Each repository's PRs are their own list, so
    there is no single view of everything waiting on you.

### Editor and language servers

`LanguageService` covers diagnostics, completions, hover, document symbols and
go-to-definition. The rest of the protocol is unimplemented:

[ ] Rename symbol (`textDocument/rename`).
[ ] Find references (`textDocument/references`).
[ ] Code actions / quick fixes. A diagnostic can be read but never acted on,
    which is the single most-used thing an LSP offers after completion.
[ ] Format document (`textDocument/formatting`), and so no format-on-save.
[ ] Signature help — completions are there, parameter hints are not.
[ ] Workspace symbol search. ⌘P finds files; nothing finds a symbol.
[ ] Inlay hints and code lens.

### Search and diffs

[ ] No replace across files. `FileSearch.swift` finds and never writes.
[ ] No diff options — no ignore-whitespace, no context-line count, no way to
    hide whitespace-only changes. A reformatting commit is unreadable.

### Shortcuts

[ ] ⌘N and ⇧⌘N are not rebindable. They are `.keyboardShortcut` literals in
    `WorkspaceApp.swift:45` and `:50` instead of `ShortcutAction` cases, which
    is exactly what CLAUDE.md says not to do — and it makes the README's "every
    shortcut the app binds is rebindable" untrue.
[ ] README shortcut table needs a pass: ⌘, and ⇧⌘O are each listed twice, and
    ⌃⌘P documents a command that does not exist.
