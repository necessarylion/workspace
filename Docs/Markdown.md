# Markdown: swift-markdown

**Done.** This was written as a plan and is kept as the reasoning — every stage
at the bottom has landed. What follows is why the parser is what it is; the walk
itself is `Support/MarkdownParser.swift`.

Markdown is rendered three times over in this app — a `.md` file in the viewer, a
pull request's description, and every comment on it — and all three go through one
type, `MarkdownText` in `Views/MarkdownPreview.swift`. Its parser *was*
hand-rolled and **line-by-line**: each source line was classified on its own
(`parse(_:depth:)`), which is where every remaining gap came from. A paragraph
hard-wrapped at 80 columns became one `.paragraph` per line and was drawn as a
ladder; a continuation line under a bullet lost its bullet; `Title` over `=====`
came out as a paragraph and a rule; a fence inside a list item was hoisted out of
it. None of these were small bugs with small fixes — they were all the same
missing thing, which is a block tree.

**The decision: replace the parser, keep the renderer.**
[swiftlang/swift-markdown](https://github.com/swiftlang/swift-markdown) is a
parser and nothing else — an immutable, thread-safe markup tree over
[swift-cmark](https://github.com/swiftlang/swift-cmark), the same cmark-gfm both
hosts use. So `MarkdownText.Block`, every view under it, `MarkdownPDF`,
`MarkdownCodeHighlighter`, the palettes, the mermaid and draw.io fences and the
mention chips all stay. Only `blocks(in:relativeTo:)` and `parse(_:depth:)`
change: a `MarkupWalker` builds the same blocks the views already draw.

This was measured rather than assumed — every claim below was run against
swift-markdown 0.8.0 before being written down.

## What the parser answers for free

Each of these was a line in `TODO.md`, and each one is a node in the tree rather
than code of ours:

| Today | What the tree gives |
| --- | --- |
| Hard-wrapped paragraphs come apart | **one** `Paragraph` holding `SoftBreak`s |
| A continuation line under a bullet becomes its own paragraph | it stays inside the `ListItem`'s paragraph |
| Nested checklists lose their indent | a nested `UnorderedList` *inside* the item — structure, not an `indent:` we carry |
| `1. [ ] thing` is not a checklist | `OrderedList` → `ListItem checkbox: [ ]` |
| Setext headings render as paragraph + rule | `Heading level: 1` |
| Rules only match `---` and `***` | `___`, `----` and `- - -` all give `ThematicBreak` |
| Indented code blocks are prose | `CodeBlock language: none` |
| Reference-style links stay literal | resolved to a `Link` with its destination; the `[ref]: …` line disappears |
| Table alignment is dropped | `columnAlignments: \|l\|c\|r\|` |
| A fence inside a list item is hoisted out | nested, as written |
| Checklists are not clickable | every node carries a **source range** (line:column) |
| No outline for long documents | `Heading` nodes, each with a range |

The source ranges are the interesting one. A tickable checkbox has never been
about drawing a toggle — it is about knowing *which* `[ ]` in the file to flip,
and the tree says so exactly. For a `.md` file the write-back is `OpenDocument`;
for a pull request comment it is the edit path that already exists (see #19).

## What it does not answer

Worth writing down so it is not investigated twice. The package attaches exactly
three cmark extensions — `table`, `strikethrough`, `tasklist` — and no others:

- **Bare URLs are still not links.** No autolink extension, so
  `https://example.com` stays `Text`. Ours to do.
- **Footnotes are worse than missing.** `[^1]: note` is read as a *reference link
  definition*, so `text[^1]` comes out as a link pointing at `note`. Adopting the
  library does not fix footnotes, and this mangling must be caught rather than
  passed through.
- **`:tada:`, `#123` and `@name`** are not Markdown at all. They are an inline
  scan over `Text` nodes — and so is autolinking a bare URL, so that is one piece
  of work rather than four. `CommitMessageText` already navigates `#123`.
- **HTML arrives raw.** `<table>`, `<details>` and `<!-- … -->` come through as
  `HTMLBlock` with the literal string in it, and `<kbd>` as `InlineHTML`. So
  `Support/MarkdownHTMLText.swift` stays exactly as load-bearing as it was. A
  `<table>` *does* arrive whole in one `HTMLBlock`, which turned out to be enough
  to read the plain shape — `<tr>`, `<th>`, `<td>` — into the same headers and
  rows a `|…|` table gives. Anything past that (a `colspan`, an `align=` on a
  cell) wants [SwiftSoup](https://github.com/scinfu/SwiftSoup) rather than more
  of the tag scanner.
- **A bare `- [ ]` is still not a box**, because cmark-gfm wants text after the
  brackets. That stops being a bug worth fixing: both hosts *are* cmark-gfm, so
  matching it is fidelity. The `TODO.md` line should be struck rather than done.
- Everything interactive or visual — the copy button on a fence, click-to-zoom on
  an image, the checkbox's own control — is renderer work either way. The parser
  only makes the checkbox's *effect* possible.

## Why not the library that renders too

[swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) would draw
it as well, with themes, block styles and a code-highlighter hook. It is the
wrong trade here: raw HTML is not rendered at all, which is a straight regression
for the bot comments both hosts serve; its checkboxes are read-only; and mermaid,
draw.io, the palettes and the mention chips would all have to be re-plumbed
through its theming to arrive back where we already are. `Down` and `Ink` render
to `NSAttributedString` or HTML, meaning a `WKWebView` or the loss of the SwiftUI
blocks — the wrong direction for a column that hosts live diagram views.

## The stages

Each landed on its own and left the app working.

1. ✅ **The tree, behind the same door.** The two packages are in `Package.swift`,
   pinned exactly at 0.8.0. `MarkdownText.blocks(in:relativeTo:links:)` calls
   `MarkdownParser`, and `parse(_:depth:)` is gone. This is where the whole first
   table arrived at once.
2. ✅ **Lists became nested.** `Block` no longer carries `bullet(indent:)`,
   `numbered(indent:)` and `task(done:)` as flat rows; there is one `.list` case
   holding a `MarkdownList`, whose items hold blocks of their own. Answered in
   `MarkdownListView`, and in `MarkdownHTML` — which writes the marker and the
   item's column out by hand rather than as `<ul>`, so the page and the PDF
   cannot drift.
3. ✅ **HTML against a flat stream.** `MarkdownHTMLText.events(in:)` reads one raw
   block into `open`/`close`/`summary`/`table`/`markdown`, and `ContainerStack`
   in the parser keeps the stack. Loose HTML — a README's
   `<p align="center"><img …></p>` — is handed back as Markdown and re-read as a
   document of its own, which is what makes it a picture.
4. ✅ **One inline pass.** `MarkdownInline.decorated(_:links:inLink:)`, over `Text`
   nodes only, doing the escaping in the same walk. The footnote hazard is caught
   in both directions: a definition cmark left as a paragraph is lifted to the
   end of the document, and one it ate as a link reference definition is drawn as
   the marker it was rather than as a link to the note's words.
5. ✅ **Ticking a box.** `MarkdownList.Item.line` and `MarkdownTask.toggling`. For
   a `.md` file the tick lands in `OpenDocument` as an unsaved edit — ⌘S writes
   it, the way every other edit in the app is written. For a PR it goes back
   through `updateDescription` / `updateComment`, from what the host holds rather
   than from what is drawn.
6. ✅ **The rest of the list.** Table alignment, the outline behind a button in
   the corner, the copy button on hover, and a picture that opens at full size.

## What it cost, and what it did not

- **The parse is cached exactly as it was.** `MarkdownText` is drawn on every pass
  of a pull request view, so `cachedBlocks` and `cachedInlineText` both survived —
  the `MarkdownLinks` of the document joined the key, since the same `#123` is
  another repository's pull request. A tree costs 2–7 ms on this repository's own
  documents, and it is built once per (text, folder, repository).
- **Comments are dropped from the tree, not from the text.** `strippingComments`
  is gone. It cut whole lines out before parsing, which moved every line number
  after them — and a source range is the one thing every write-back depends on.
- **The blocks still carry Markdown strings**, so the views, `MarkdownPDF`,
  `MarkdownCodeHighlighter`, the palettes, the mermaid and draw.io fences all
  stayed. The price is that everything the parser writes into a block has to be
  escaped for the second read, which is why `MarkdownInline` owns both jobs.
- Both packages are ordinary SwiftPM dependencies with no asset catalogue and
  nothing fetched at runtime, so the offline rule in `CLAUDE.md` holds.
