# LSP

Code intelligence — diagnostics, go-to-definition, completions, the symbol list
and the server line in the status bar — comes from language servers the user
already has on `PATH`. Nothing is bundled. `gh`, `bkt` and `claude` are treated
the same way, and `ManagedLanguageServers` covers the "install it for me" case
for the ones npm publishes.

The editor is [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor),
so the app owns neither the text view nor the highlighting. What it owns is the
conversation with the server, and the join between the two.

## The pieces

- **`LSP/LSPConnection.swift`** — JSON-RPC over stdio, ours. An actor; requests
  carry a timeout, notifications do not.
- **`LSP/LSPTypes.swift`** — the slice of the protocol this app speaks. Decoders
  are deliberately loose: servers are free with their return shapes, and a hover
  body may be a string, an object, or an array of either.
- **`LSP/LanguageService.swift`** — one server, scoped to a project root and a
  language. Owns the handshake, the open-document set and the version counters.
- **`LSP/LanguageServerRegistry.swift`** — language → binary, one server per
  (root, language), started lazily the first time a matching file is opened and
  prewarmed from the dashboard.
- **`LSP/LanguageServerConfiguration.swift`**, **`LanguageServerOptions.swift`**,
  **`ManagedLanguageServers.swift`** — which servers exist, their flags, and the
  ones the app can fetch for you.
- **`Editor/LanguageServerCoordinator.swift`** — the join to the editor. One per
  open file.

The coordinator is a `TextViewCoordinator` **and** a `TextViewDelegate`, and it
has to be both. The first is how the package hands an app the controller it
builds itself; the second is the only way to see an edit *before* it is applied,
which is what makes incremental sync possible at all.

It also serves as the package's `JumpToDefinitionDelegate` and
`CodeSuggestionDelegate` — ⌘-click and the completion list are the package's
window and keyboard, and only the answers are ours.

## Document sync

`textDocument/didChange` states each edit as a range in the document **as the
server last saw it**. Once the text has changed that document is gone and the
range cannot be recovered, so it is read in
`textView(_:willReplaceContentsIn:with:)`, before the replacement lands, and
queued.

Two things about the queue matter:

- **Edits are batched, not merged.** Every one still travels, in order, because
  each states its range against the document the ones before it produced.
- **The batch is flushed at most once every 250 ms.** Typing is not one edit but
  dozens, and a server handed each keystroke separately spends the whole burst
  re-analysing text that is already stale.

The line and character numbers come from the layout manager's line store
(`textLineForOffset`), which is a tree lookup. Counting newlines instead would be
a walk over the whole document on every keystroke — the exact shape of the
problem that made the old editor stall.

**The server is asked before ranges are sent.** `initialize` replies with
`textDocumentSync`, and `LanguageService.syncKind` keeps it. A server that only
advertised `full` gets the whole file; so does an edit whose pre-edit range could
not be resolved. Sending ranges to a server that never asked for them leaves it
holding text that quietly diverges from what is on screen, and every answer after
that is about a document nobody is looking at. This is worth the twenty lines: it
is the one thing the editor cannot guess.

## What the package gives, and what it does not

Gives: the ⌘-hover underline and ⌘-click that arm go-to-definition, the
completion window with its filtering keyboard, and — usefully — its own ⎋. Both
the completion list and the find panel install `NSEvent` local monitors when they
open, and a local monitor added later runs first, so both swallow ⎋ before the
app's own handler sees it. `EscapeKey` needed no case for either.

Does not give: **anything for diagnostics.** The word does not appear in
CodeEditSourceEditor 0.15.2. There is no inline message, no gutter marker and no
peripheral for one. So diagnostics land in `OpenDocument.diagnostics`, and from
there in the status bar's error and warning counts — which is real value, and is
not the squiggle under the offending token that the old editor drew. Underlining
in the text again means either drawing it ourselves through a coordinator, or the
package growing support for it; `TextAttachmentManager` looks like where it would
go.

## Why not ChimeHQ

An earlier version of this document chose to delete our JSON-RPC and typed
subset in favour of `LanguageClient` + `LanguageServerProtocol`, as
[CodeEdit](https://github.com/CodeEditApp/CodeEdit) does. That was reversed
before any of it was written, for one blocking reason and two smaller ones.

**The blocker: Vue.** `vue-language-server` runs in hybrid mode — it answers the
template and the styles itself and forwards everything about types to whatever
TypeScript server the *client* is running. That forwarding is not in the
protocol. It arrives as a `tsserver/request` notification and is answered with
`tsserver/response`, and in `LanguageServerProtocol` both directions are closed
enums: `ServerNotification.Method` has seven cases, `handleNotification` throws
`unrecognizedMethod` for anything else, and `sendNotification` takes a
`ClientNotification` there is no way to extend. Vue support would have had to be
rebuilt on a second transport, or on a hand-written `ServerConnection`
conformance — which is most of what adopting the package was meant to avoid.

The smaller two: the dependency graph does not "barely widen" — `LanguageClient`
brings `LanguageServerProtocol`, `JSONRPC`, `FSEventsWrapper`, `swift-glob`,
`ProcessEnv`, `Semaphore` and `Queue`, eight packages rather than two. And the
code it would replace is not the risky part: our transport has been carrying
every server in the catalog for as long as the app has had one.

What the plan was right about is that incremental, coalesced sync is strictly
better than the full-text-on-a-debounce it replaced. That idea was worth copying
on its own, and it is what the section above describes. The macOS floor
(`.macOS(.v11)`) and tools versions (5.8/5.9) were both checked and would have
been fine; they were not why.

## Not done yet

- **Hover documentation.** `LanguageService.hover` is there and nothing calls it.
  The old `HoverInfoWindow` went with the hand-rolled editor, and the package has
  no hover peripheral, so this needs a window of our own again.
- **Diagnostics in the text**, as above.
- **Semantic tokens** as a second `HighlightProviding` beside tree-sitter. Worth
  being clear about what this buys: not more colours — it funnels through the
  same closed 21-case `CaptureName` that costs us 56 captures today, see
  `Editor/EditorThemeBridge.swift` — but *accuracy*, a type the compiler resolved
  instead of one the grammar guessed.
- **Trigger characters from the server.** `completionTriggerCharacters()`
  currently returns a fixed set that suits the languages here. `initialize`
  reports the server's own; we do not read it back yet.
- **Snippets** are flattened. `foo(${1:bar})` becomes `foo(bar)` — never a
  placeholder left in the file, but no tab stops either.

## Also worth knowing

- **Large files are excluded on purpose.** See `OpenDocument.largeFileNote`.
  `didOpen` sends the whole text, and the answer to a 3.5 MB minified bundle is a
  diagnostic per line of something nobody is editing. No coordinator is even
  built for one.
- **A file outside every added repository gets no server**, because there is no
  root to start one in.
- **URIs are compared as paths, not as strings.** Servers spell the same file
  differently — `rust-analyzer` and `vtsls` percent-encode where we do not — and a
  diagnostic keyed under a spelling we did not recognise is one silently dropped.
- **Saves are sent.** Not a nicety: `rust-analyzer` runs `cargo check` on save
  and nothing before it, so without `didSave` a Rust file's diagnostics never
  change.
- **Vue needs two servers holding the same file.** That is what
  `LanguageServerRegistry.companionService(for:root:)` is for. The companion is
  asked nothing and is sent every edit.
- Anything added has to work for every language in `LanguageServerCatalog`, not
  just the one it was written against — the same instinct as host parity for
  pull requests.
