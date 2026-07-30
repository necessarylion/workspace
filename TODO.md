## Still missing in PR details

Roughly in order of how much each one hurts. Everything below was checked
against `PullRequestDetailView.swift`, `PullRequestSidebar.swift` and the
`PullRequest*` models — none of it exists yet, on either host.

- [ ] Mergeable / conflict state. Nothing reads `mergeable` or
      `mergeStateStatus`, so Merge is always offered at full strength and a
      conflict is only discovered when the host refuses. The sync badge answers a
      different question ("behind the target"), not "will this merge".
- [ ] Delete a comment. Reply, edit and resolve are all there; delete is not, so
      a mistyped comment has to be finished on the web.
- [ ] Edit the title. The description has a full Markdown editor, but the title —
      the thing every list shows — can only be changed in the browser.
- [ ] Draft ↔ Ready for review. `pr.isDraft` is drawn as a badge and never
      toggled, so marking a PR ready needs the host.
- [ ] Delete the source branch on merge. The merge sheet says outright "nothing is
      deleted"; there is no option to, which is the normal end of a merge.
- [ ] Remove a reviewer, and re-request a review. `addReviewers` is the only
      write; somebody added by mistake stays, and a stale approval cannot be
      asked for again.
- [ ] Labels. Not in the model, not in the sidebar, not editable — and on most
      repos they are how a PR is triaged.
- [ ] Assignees. Same: `PullRequestReviewer.swift` only mentions the GitHub
      assignees endpoint as a source of *candidates*, never as a field to show or
      set.
- [ ] Reactions on comments (👍/🎉/…). Both hosts have them; nothing here reads
      or posts one, so a comment can only be answered with another comment.
- [ ] Linked issues ("Closes #123"). Not parsed, not shown, and not opened —
      unlike `#123` in a commit message, which already navigates.
- [ ] Per-file "viewed" checkbox in the diff. `DiffFileList` selects a file but
      keeps no read/unread state, so a long review loses its place on every
      reload.
- [ ] Suggested changes (` ```suggestion ` blocks) with an Apply button. They
      render as plain fenced code today.
- [ ] Reopen a closed PR. The reject sheet says it "can be reopened on GitHub" —
      which is exactly where you have to go to do it. Once `state != .open` the
      whole action bar disappears.
- [ ] Unresolved-thread count in the summary bar. It says "N comments"; what a
      reviewer actually wants before merging is how many threads are still open.
- [ ] Change the target branch. Fixed at whatever the PR was opened against.

## Still missing in Markdown preview

The list that used to be here was one bug written out sixteen ways: the parser
read the document a line at a time and there was no block tree. It has been
replaced by [swift-markdown](https://github.com/swiftlang/swift-markdown) —
cmark-gfm, which is what both hosts render a comment with — so hard-wrapped
paragraphs, multi-line list items, nested and ordered checklists, setext
headings, every spelling of a horizontal rule, indented code blocks,
reference-style links, table alignment and a fence inside a list item are all
answered by the tree rather than by code of ours. Bare URLs, `:tada:`, `#123`,
`@name` and footnotes are one scan over the text on top of it, checkboxes tick
and write back, fenced blocks have a copy button, pictures open at full size and
a long document has an outline. See `Docs/Markdown.md` for the reasoning and
`Support/MarkdownParser.swift` for the walk.

Struck rather than done: **a bare `- [ ]` is not a box**. cmark-gfm wants text
after the brackets, and both hosts *are* cmark-gfm — so matching it is fidelity,
not a bug.

What is left, and both need a real HTML parser rather than the tag scanner in
`Support/MarkdownHTMLText.swift`:

- [ ] HTML tables are read, but only the plain shape — `<table>`, `<tr>`, `<th>`,
      `<td>`. A `colspan`, a `rowspan` or an `align=` on a cell is dropped, and a
      table with a blank line inside it is split by cmark before we ever see it.
      [SwiftSoup](https://github.com/scinfu/SwiftSoup) is the tool if that ever
      matters.
- [ ] `<img>` inside a table cell is drawn as its alt text. A picture is a block
      of its own here, and a cell has nowhere to put one.

## Missing elsewhere in the app

A sweep over the rest — git, the PR board, the editor and its language servers,
search, shortcuts. Same rule as above: each line was checked against the code,
not against the README.

### Git

- [ ] No branch switcher. Only two branches can ever be checked out: the
      repository's default (the dashboard button) and a PR's source branch. There
      is no list of local or remote branches, and no create, rename or delete.
      `git for-each-ref` appears exactly once, in `DefaultBranch.swift:114`, and
      only to guess which branch is the default.
- [ ] No stash. Nothing to park half-done work on — which compounds the one
      above, since switching branches is what stashing is usually for.
- [ ] No blame. No way to ask who wrote a line, or why.
- [ ] No history for a single file. The dashboard lists the repository's recent
      commits; there is no log for the file you are reading.
- [ ] No amend, revert or cherry-pick. Commit and push are there, so fixing the
      commit you just made means dropping to the terminal.
- [ ] No tags. Not listed, not created — so nothing in the app says what shipped.
- [ ] No diff between two arbitrary refs. A PR's diff and a commit's patch are
      the only two; `main...my-branch` cannot be asked for.
- [ ] No submodule awareness at all.

### The PR board

- [ ] **You cannot create a pull request.** Read, review, comment, approve, merge
      and reject are all there; opening one is not. The README's shortcut table
      lists ⌃⌘P "Create PR with Claude Code" and nothing in the code implements
      it — there is no such `ShortcutAction` case and no handler.
- [ ] The board has no filter or search. `PullRequestTable.swift` sorts and never
      filters — no by-author, no "needs my review", no title search.
- [ ] No cross-repo review inbox. Each repository's PRs are their own list, so
      there is no single view of everything waiting on you.

### Editor and language servers

`LanguageService` covers diagnostics, completions, hover, document symbols and go-to-definition. The rest of the protocol is unimplemented:

- [ ] Rename symbol (`textDocument/rename`).
- [ ] Find references (`textDocument/references`).
- [ ] Code actions / quick fixes. A diagnostic can be read but never acted on,
      which is the single most-used thing an LSP offers after completion.
- [ ] Format document (`textDocument/formatting`), and so no format-on-save.
- [ ] Signature help — completions are there, parameter hints are not.
- [ ] Workspace symbol search. ⌘P finds files; nothing finds a symbol.
- [ ] Inlay hints and code lens.

### Search and diffs

- [ ] No replace across files. `FileSearch.swift` finds and never writes.
- [ ] No diff options — no ignore-whitespace, no context-line count, no way to
      hide whitespace-only changes. A reformatting commit is unreadable.

### Shortcuts

- [ ] ⌘N and ⇧⌘N are not rebindable. They are `.keyboardShortcut` literals in
      `WorkspaceApp.swift:45` and `:50` instead of `ShortcutAction` cases, which
      is exactly what CLAUDE.md says not to do — and it makes the README's "every
      shortcut the app binds is rebindable" untrue.
- [ ] README shortcut table needs a pass: ⌘, and ⇧⌘O are each listed twice, and
      ⌃⌘P documents a command that does not exist.
