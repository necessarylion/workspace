# LSP: the plan

The language server layer is **dormant**. `Sources/Workspace/LSP/` is still in
the tree and nothing calls it: the editor is now
[CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor), and
every feature that used to reach a server went with the hand-rolled
`CodeEditorController` that drove it. `OpenDocument.diagnostics` and
`.symbols` stay empty; the status bar has nothing to say.

This is the plan for bringing it back. Nothing here is implemented.

## What is gone

Attached to text offsets in the old `NSTextView`, so none of it survived:

- diagnostics — underlines in the text, severity dots in the gutter, and the
  list `OpenDocument.diagnostics` fed
- ⌘-click go-to-definition, and the ⌘-hover underline that armed it
- hover documentation
- completions (⌃Space)
- the document symbol list
- the server status line in the status bar

## What is still here

- `LSP/LSPConnection.swift` — hand-rolled JSON-RPC over stdio
- `LSP/LSPTypes.swift` — a typed subset of the protocol
- `LSP/LanguageService.swift` — one actor per server, request/response
- `LSP/LanguageServerRegistry.swift` — language → binary, started lazily per
  project root
- `LSP/LanguageServerConfiguration.swift`, `LanguageServerOptions.swift`,
  `ManagedLanguageServers.swift` — which servers exist, their flags, and the
  ones the app can install for you

Servers are whatever is on `PATH`. Nothing is bundled. That part is right and
is not up for reconsideration below.

## What CodeEdit does

Worth reading before choosing, because the answer is *not* "the same as us":
[CodeEdit](https://github.com/CodeEditApp/CodeEdit) does not implement the
protocol at all.

| Layer | Theirs |
| --- | --- |
| Transport | ChimeHQ `JSONRPC` |
| Protocol types | ChimeHQ `LanguageServerProtocol` |
| Handshake, lifecycle | ChimeHQ `LanguageClient` → `InitializingServer` |
| Per-server object | `LanguageServer<DocumentType>` + ~20 `LanguageServer+<Capability>.swift` extensions, one per request |
| Open files, caching | `LanguageServerFileMap`, `LSPCache` |
| Document sync | `LSPContentCoordinator` — a `TextViewCoordinator` **and** a `TextViewDelegate` |
| LSP-driven colour | `SemanticTokenHighlightProvider`, a `HighlightProviding` |
| Installing servers | `Registry/` — package managers, sources, the lot |

Two pieces of it matter more than the rest.

**Document sync is incremental and coalesced.** `LSPContentCoordinator` takes
the LSP range in `textView(_:willReplaceContentsIn:with:)`, yields it into an
`AsyncStream`, and chunks the stream on a repeating clock:

```swift
for await events in stream.chunked(by: .repeating(every: .milliseconds(250), clock: .continuous)) {
    try? await languageServer?.documentChanged(uri: uri, changes: events.map { … })
}
```

Our old controller re-sent the **whole file** on a 300 ms debounce. Theirs is
strictly better and is the model to copy whichever route we take.

**Semantic tokens arrive as a highlight provider.**
`SourceEditor(highlightProviders:)` takes an array, and
`SemanticTokenHighlightProvider` composes *alongside* `TreeSitterClient` rather
than replacing it — `SemanticTokenMap` translates LSP token types and modifiers
into the package's `CaptureName`. Note what this does and does not buy: it
cannot widen the palette, because it funnels through the same closed 21-case
`CaptureName` that costs us 56 captures today (see the note in
`Editor/EditorThemeBridge.swift`). What it buys is *accuracy* — a type the
compiler resolved instead of a name the grammar guessed at.

## The decision: plan B

- **Plan A — keep our JSON-RPC, re-wire it.** Write a `TextViewCoordinator` to
  drive `LanguageService`. Cheapest, no new dependencies, `ManagedLanguageServers`
  and `PATH` discovery keep working untouched. But we go on maintaining a
  protocol implementation, and converting full-text sync to incremental is on us.
- **Plan B — adopt ChimeHQ, as CodeEdit does.** Delete our JSON-RPC and typed
  subset for `LanguageClient` + `LanguageServerProtocol`. Real capability
  negotiation, incremental sync, and every request type already written.

**Plan B.** The dependency graph barely widens — `LanguageClient` is by the same
author as `SwiftTreeSitter`, which already arrives under `CodeEditLanguages` —
and the code we delete is the code most likely to be subtly wrong at the
protocol level.

We do **not** port their `Registry/`. Our servers come from the user's `PATH`,
which suits an app that already treats `gh`, `bkt` and `claude` that way, and
`ManagedLanguageServers` already covers the "install it for me" case.

## Staging

1. **Dependencies, and one server end to end.** `LanguageServerRegistry` onto
   `InitializingServer`, `PATH` discovery kept as it is. Pilot with one server —
   `sourcekit-lsp` or `tsserver`. Nothing user-visible yet.
2. **Document sync.** An `LSPContentCoordinator` equivalent: `TextViewCoordinator`
   plus `TextViewDelegate`, incremental, coalesced. Do this before anything that
   consumes it — a server fed wrong ranges fails in ways that look like
   unrelated bugs everywhere else.
3. **Diagnostics.** Highest value, and the package has somewhere to put them:
   inline messages via `configuration.peripherals`, plus gutter markers.
   Restores `OpenDocument.diagnostics` and the status line.
4. **Go-to-definition.** Via the package's `JumpToDefinitionDelegate`, which
   already handles ⌘-click; wire its result to `WorkspaceStore.openFile`.
5. **Completions.** Via `CodeSuggestionDelegate`. This re-opens the ⎋ question:
   the suggestion list is a separate `NSWindow`, so `EscapeKey.leavesEscapeAlone`
   needs a case for it again — that case existed for `CodeTextView` and was
   removed with it.
6. **Hover, document symbols.** Lowest value; last.
7. **Optional: semantic tokens** as a second `HighlightProviding` beside
   tree-sitter, for accuracy rather than for more colours.

Steps 1–3 are most of the value. Stop and reassess after 3.

## To check before starting

Neither is confirmed:

- whether `LanguageClient`'s macOS floor and its Swift 6 concurrency
  annotations fit this target, which builds in Swift 6 language mode
- whether it forces a `swift-tools-version` bump

Both are quick to answer and both are cheaper to answer before step 1 than
during it.

## Also worth knowing

- Large files are excluded on purpose and should stay excluded — see
  `OpenDocument.largeFileNote`. The old reason still holds: `didOpen` sends the
  whole text, and the answer to a 3.5 MB minified bundle is a diagnostic per
  line of something nobody is editing.
- Vue needs two servers open on the same file: the Vue server does the asking,
  the TypeScript server only has to be holding the same text. That is what
  `LanguageServerRegistry.companionService(for:root:)` is for, and whatever
  replaces it needs the same idea.
- `PullRequest`-style host parity does not apply here, but the same instinct
  does: anything added has to work for every language in
  `LanguageServerCatalog`, not just the one it was written against.
