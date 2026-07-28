import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import SwiftUI

/// The join between one open file and its language server.
///
/// The editor is CodeEditSourceEditor's now, so this is the whole of the app's
/// side of the conversation: it opens the document with the server, keeps the
/// server's copy in step as the text is edited, and turns what comes back into
/// the things the window shows — diagnostics in the status bar, the symbol list,
/// ⌘-click go-to-definition and the completion list.
///
/// One of these belongs to one open file. `TextViewCoordinator` is how the
/// package lets an app reach the controller it builds itself, and the same
/// object also conforms to `TextViewDelegate` — which is the only way to see an
/// edit *before* it is applied, and the only reason incremental sync is possible
/// at all (see ``queue(_:)``).
///
/// Not `@MainActor`, though nearly everything it does is: `TextViewCoordinator`
/// carries no actor, so an isolated conformance does not compile. Every callback
/// arrives from AppKit's own lifecycle, which is the main thread by
/// construction, hence `assumeIsolated` rather than a hop — a hop would land
/// after the edit it was told about.
///
/// `@unchecked Sendable` follows from the same fact, and is the narrowest way to
/// say it. Nothing here is touched off the main thread — the isolated members
/// say so, and the two `assumeIsolated` callbacks are the package calling from
/// its own main-thread lifecycle — but the compiler cannot see that through a
/// protocol that carries no actor, and `withObservationTracking` hands its
/// `onChange` over as `@Sendable`.
final class LanguageServerCoordinator: TextViewCoordinator, TextViewDelegate, @unchecked Sendable {
    private let document: OpenDocument
    private let root: URL
    private weak var store: WorkspaceStore?

    private var service: LanguageService?
    /// The second server this file wants open alongside its own — `.vue` only.
    /// It answers nothing; it only has to be holding the same text, or every
    /// type in a `<script>` block is resolved against the file as last saved.
    private var companion: LanguageService?
    private weak var controller: TextViewController?

    /// Edits waiting to be sent, oldest first.
    private var pending: [LSP.TextChange] = []
    private var flushTask: Task<Void, Never>?
    /// The in-flight `didOpen`, held so that ``destroy()`` can wait for it.
    ///
    /// The handshake behind it can run for tens of seconds, and a `didClose` that
    /// overtook it would find nothing open, return, and leave the server holding a
    /// document that is never closed — analysing a file nobody is looking at, and
    /// one more leaked open on every teardown.
    private var openTask: Task<Void, Never>?
    /// Set when an edit could not be expressed as a range, so the next send has
    /// to be the whole file. One unexpressed edit makes every later range in the
    /// batch a lie, and the only honest repair is to restate the document.
    private var needsFullText = false
    private var isRunning = false
    /// Whether `didOpen` has actually reached the server. Until it has, there is
    /// nothing to send edits against.
    private var isOpen = false

    /// The last completion list, and the offset the query started at, so a
    /// keystroke can filter what is already on screen without asking again.
    private var suggestions: [LSP.CompletionItem] = []
    private var suggestionOrigin: Int?

    init(document: OpenDocument, root: URL, store: WorkspaceStore?) {
        self.document = document
        self.root = root
        self.store = store
    }

    /// What the server calls this file.
    private var uri: String { document.url.absoluteString }

    /// Every server this file is open with. The companion gets the same text and
    /// the same edits, and is asked nothing.
    private var targets: [LanguageService] { [service, companion].compactMap(\.self) }

    // MARK: - Lifecycle

    func prepareCoordinator(controller: TextViewController) {
        MainActor.assumeIsolated {
            self.controller = controller
            start()
        }
    }

    @MainActor
    private func start() {
        // A minified bundle is not a file anyone is editing, and `didOpen` sends
        // the whole text — see `OpenDocument.largeFileNote`.
        guard !document.isLargeFile, !isRunning else { return }

        let registry = LanguageServerRegistry.shared
        guard let service = registry.service(
            for: document.url,
            language: document.language,
            root: root
        ) else { return }

        isRunning = true
        self.service = service
        self.companion = registry.companionService(for: document.url, root: root)

        service.addDiagnosticObserver(self) { [weak self] uri, diagnostics in
            guard let self, self.isOurs(uri) else { return }
            self.document.diagnostics = diagnostics
        }

        observeStatus()
        observeSaves()
        openIfNeeded()
    }

    /// Opens the document with every server this file has.
    ///
    /// Re-runnable, and deliberately so. `LanguageService.startIfNeeded` drops its
    /// task when a start fails, so a server that was not installed when the file
    /// was opened gets another go — and that second start is worth nothing unless
    /// the document is opened with it as well. Everything that waits on the
    /// server comes through here first for that reason. A second call after a
    /// successful open does nothing: ``isOpen`` stops it, and `LanguageService`
    /// counts opens per URI besides.
    @MainActor
    private func openIfNeeded() {
        guard isRunning, !isOpen, openTask == nil, let service else { return }

        let text = document.text
        // Every server holds this file under the *file's* language, not its own.
        // See `LanguageService.open(uri:text:languageID:)` — the companion is the
        // whole reason that parameter exists.
        let languageID = service.definition.languageID
        openTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Only the answering server decides. `open` returns false when the
            // process never started — nothing was sent, and `LanguageService`
            // will drop every `didChange` after it — so calling the document
            // open would strand the edits: `flush()` would clear `needsFullText`
            // against a server that is not listening, and the restatement owed
            // when it does come up would be gone.
            var opened = false
            for target in self.targets {
                let didOpen = await target.open(uri: self.uri, text: text, languageID: languageID)
                if target === self.service { opened = didOpen }
            }
            self.openTask = nil
            guard self.isRunning, opened else { return }
            self.isOpen = true
            self.catchUp()
        }
    }

    /// Says everything the server missed while it was starting.
    ///
    /// Its own task, so that ``openTask`` ends with the notification it stands
    /// for. Both things that wait on that task want the `didOpen` and nothing
    /// after it: ``destroy()`` only needs `didClose` to follow it, and a ⌘-click
    /// arriving mid-startup should not sit through a symbol request's 8 s
    /// timeout. Guarded on ``isRunning``, so it falls away with the pane.
    @MainActor
    private func catchUp() {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            // Anything typed while the server was starting was held back rather
            // than sent — see ``flush()`` — so the file is restated now that it
            // will be listened to.
            if self.needsFullText || !self.pending.isEmpty {
                await self.flush()
            }
            await self.refreshSymbols()
        }
    }

    func destroy() {
        MainActor.assumeIsolated {
            isRunning = false
            isOpen = false
            flushTask?.cancel()
            flushTask = nil
            pending.removeAll()
            service?.removeDiagnosticObserver(self)

            let closing = targets
            let uri = self.uri
            // Not cancelled — the `didOpen` it is in the middle of has to finish,
            // or the `didClose` below has nothing to close. See ``openTask``.
            let opening = openTask
            openTask = nil
            service = nil
            companion = nil
            controller = nil
            document.languageServerStatus = ""

            Task {
                await opening?.value
                for target in closing { await target.close(uri: uri) }
            }
        }
    }

    /// Whether a URI the server sent back names this file.
    ///
    /// Compared as a path and not as a string: servers spell the same file
    /// differently — `rust-analyzer` and `vtsls` percent-encode where we do not
    /// — and a diagnostic keyed under a spelling we do not recognise is a
    /// diagnostic silently dropped.
    private func isOurs(_ incoming: String) -> Bool {
        incoming == uri
            || URL(string: incoming)?.standardizedFileURL == document.url.standardizedFileURL
    }

    // MARK: - Status and saves

    /// Mirrors the server's state into the status bar, and keeps mirroring it.
    ///
    /// `LanguageService` is `@Observable`, so this re-registers itself on every
    /// change rather than polling — a server can sit in "starting…" for the best
    /// part of a minute, and that minute is exactly when the user wants to know.
    @MainActor
    private func observeStatus() {
        guard isRunning, let service else { return }
        document.languageServerStatus = "\(service.definition.displayName) — \(service.status.label)"
        withObservationTracking {
            _ = service.status
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
    }

    /// Tells the server when the file is written.
    ///
    /// Not a nicety: plenty of servers only re-check a project on save —
    /// `rust-analyzer` runs `cargo check` then, and nothing before it — so
    /// without this the diagnostics for a Rust file never change.
    @MainActor
    private func observeSaves() {
        guard isRunning else { return }
        withObservationTracking {
            _ = document.saveRevision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                // Re-armed *before* the awaits, not after. `withObservationTracking`
                // fires once, and the work below runs for as long as the symbol
                // request's 8 s timeout — a second ⌘S inside that window would
                // change `saveRevision` while nothing was watching it, which is
                // exactly the save that `rust-analyzer` needs to see.
                self.observeSaves()
                let text = self.document.text
                for target in self.targets {
                    await target.save(uri: self.uri, text: text)
                }
                await self.refreshSymbols()
            }
        }
    }

    // MARK: - Document sync

    /// The pre-edit range, which is the whole reason this conforms to
    /// `TextViewDelegate` instead of settling for `textViewDidChangeText`.
    ///
    /// `textDocument/didChange` states each edit against the document as the
    /// server last saw it. By the time the text has changed that document is
    /// gone and the range cannot be recovered — so it is read here, before the
    /// replacement is applied, and queued.
    func textView(_ textView: TextView, willReplaceContentsIn range: NSRange, with string: String) {
        MainActor.assumeIsolated {
            guard isRunning else { return }
            guard let lsp = lspRange(range, in: textView) else {
                needsFullText = true
                scheduleFlush()
                return
            }
            queue(LSP.TextChange(range: lsp, text: string))
        }
    }

    @MainActor
    private func queue(_ change: LSP.TextChange) {
        pending.append(change)
        scheduleFlush()
    }

    /// Coalesces a burst of edits into one notification, at most one every
    /// 250 ms.
    ///
    /// Typing is not one edit but dozens, and a server handed each keystroke
    /// separately spends the whole burst re-analysing text that is already
    /// stale. The edits are *batched, not merged* — every one still travels, in
    /// order, because each states its range against the document the ones before
    /// it produced.
    @MainActor
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            // Released only once the send is done. Clearing it first would let an
            // edit arriving mid-send schedule a second flush, and two batches
            // racing to `change(uri:changes:)` is the one thing incremental sync
            // cannot survive — each batch's ranges are stated against the document
            // the batch before it produced. Edits arriving now are simply carried
            // into the next round, which is the batching this is here to do.
            await self.flush()
            self.flushTask = nil
            // Those carried-over edits still have to leave. Nothing else will ask
            // — `scheduleFlush` turned every one of them away while the send was
            // running — so if the user stopped typing at that moment this is the
            // only thing standing between them and a server that never hears
            // about the last thing they typed.
            //
            // Only while the document is really open, though: before that
            // `flush()` deliberately banks the edits as a restatement and returns,
            // so rescheduling on it would spin every 250 ms for the whole
            // handshake. `start()` does the restating itself once `didOpen` lands.
            guard self.isRunning, self.isOpen else { return }
            if self.needsFullText || !self.pending.isEmpty { self.scheduleFlush() }
        }
    }

    @MainActor
    private func flush() async {
        guard isRunning else { return }
        // Nothing is sent before `didOpen` has landed, and the handshake behind
        // it can take the best part of a minute — `sourcekit-lsp` prepares the
        // whole package first. An edit sent now would be dropped by the service's
        // own open-document guard and the server would hold text that never
        // catches up, so the ranges are given up and the file restated instead
        // once it is really open.
        guard isOpen else {
            needsFullText = true
            pending.removeAll()
            return
        }

        let batch = pending
        pending.removeAll()
        let wantsFullText = needsFullText
        needsFullText = false
        guard wantsFullText || !batch.isEmpty else { return }

        let text = document.text
        for target in targets {
            // A server that never advertised incremental sync gets the file.
            // Ranges it did not ask for would leave it holding text that quietly
            // diverges from what is on screen, and every answer after that is
            // about a document nobody is looking at.
            if wantsFullText || target.syncKind != .incremental {
                await target.change(uri: uri, text: text)
            } else {
                await target.change(uri: uri, changes: batch)
            }
        }
    }

    // MARK: - Symbols

    /// Nil, not empty, is what means "no answer" — see
    /// ``LanguageService/symbols(uri:)``. An empty list is a real one, and taking
    /// it for a failed request is how the outline goes on listing a function the
    /// user has just deleted.
    @MainActor
    private func refreshSymbols() async {
        guard isRunning, let service else { return }
        guard let found = await service.symbols(uri: uri), isRunning else { return }
        document.symbols = found
    }

    // MARK: - Offsets

    /// A UTF-16 offset as the protocol wants it: a zero-based line, and a
    /// zero-based offset within that line.
    ///
    /// Through the layout manager's line store rather than by counting newlines:
    /// that is a tree lookup, and this runs on every edit of every file — the
    /// scan it replaces is the kind of per-keystroke walk over the whole
    /// document that made the old editor stall.
    @MainActor
    private func position(of offset: Int, in textView: TextView) -> LSP.Position? {
        guard let line = textView.layoutManager.textLineForOffset(offset) else { return nil }
        return LSP.Position(line: line.index, character: offset - line.range.location)
    }

    @MainActor
    private func lspRange(_ range: NSRange, in textView: TextView) -> LSP.Range? {
        guard let start = position(of: range.location, in: textView),
              let end = position(of: range.upperBound, in: textView) else { return nil }
        return LSP.Range(start: start, end: end)
    }

    /// The other direction, for a range a server named.
    @MainActor
    private func offset(of position: LSP.Position, in textView: TextView) -> Int? {
        guard let line = textView.layoutManager.textLineForIndex(position.line) else { return nil }
        // Clamped: a server may name a column past the end of a line it has not
        // caught up with, and an offset outside the text would trap.
        return min(line.range.location + position.character, textView.textStorage.length)
    }
}

// MARK: - Go to definition

/// ⌘-click, and the ⌘-hover underline that arms it, are the package's; what it
/// has no way to know is where the symbol is defined.
extension LanguageServerCoordinator: JumpToDefinitionDelegate {
    @MainActor
    func queryLinks(forRange range: NSRange, textView: TextViewController) async -> [JumpToDefinitionLink]? {
        guard isRunning, let service,
              let view = controller?.textView,
              let start = position(of: range.location, in: view) else { return nil }

        // Waited for rather than checked. The first ⌘-click on a freshly opened
        // file is exactly when the server is still starting, and `definitions`
        // answers nothing at all until it is running — which the package can only
        // report as the "no definition" bezel, for a symbol that has one.
        guard await service.startIfNeeded(), isRunning else { return nil }
        // A server that failed to start when the file was opened has just been
        // given another go and taken it — but it has never seen this document.
        // Asking it about a position in a file it does not hold is how the user
        // gets "no definition" for a symbol that has one.
        openIfNeeded()
        await openTask?.value
        guard isRunning else { return nil }

        let label = (view.textStorage.string as NSString).substring(with: range)
        // Nil, not empty, when the server never answered. sourcekit-lsp can
        // spend the best part of a minute preparing a package before its first
        // reply, and "no answer yet" must not read to the package as "there is
        // no definition" — that would show the user a wrong, final answer.
        guard let locations = await service.definitions(uri: uri, position: start) else { return nil }

        return locations.compactMap { location in
            guard let target = location.fileURL else { return nil }
            let isHere = target.standardizedFileURL == document.url.standardizedFileURL

            // **Always a URL, even for a definition in this very file**, so that
            // every jump comes back through `openLink` below and is answered the
            // same way. Leaving it nil is what the type invites, and it goes wrong
            // twice over:
            //
            // `JumpToDefinitionModel` hands a URL-less link's `targetRange.range`
            // straight to `setSelectedRange` without resolving it. A position
            // built from a line and column carries no range — it reads as
            // `NSNotFound` — so selecting it took the app down.
            //
            // And it then scrolls with `scrollSelectionToVisible()`, which cannot
            // start from a cold layout (see `RevealPendingPosition`), so the caret
            // moved and the viewport did not.
            //
            // Re-presenting the file that is already showing is free:
            // `WorkspaceStore.present` returns early for the current item, so the
            // back history is untouched.
            //
            // The one cost is that two definitions in the *same* file share a link
            // id, since `JumpToDefinitionLink.id` is the URL — visible only in the
            // popover that opens when a symbol has several.
            return JumpToDefinitionLink(
                url: target,
                targetRange: CursorPosition(
                    line: location.range.start.line + 1,
                    column: location.range.start.character + 1
                ),
                typeName: label.isEmpty ? target.lastPathComponent : label,
                sourcePreview: preview(of: location, isHere: isHere) ?? "",
                documentation: nil
            )
        }
    }

    func openLink(link: JumpToDefinitionLink) {
        MainActor.assumeIsolated {
            guard let url = link.url else { return }
            // Back to counting from zero, which is what `openFile` takes. The same
            // call serves a definition in this file and one in another: the store
            // finds the open document or makes one, and either way the reveal is
            // carried out by `RevealPendingPosition`.
            store?.openFile(
                url,
                revealLine: link.targetRange.start.line - 1,
                revealColumn: link.targetRange.start.column - 1
            )
        }
    }

    /// The target's own line, for the list the package shows when a symbol has
    /// more than one definition.
    ///
    /// Read from disk for another file, and only up to a point: a definition can
    /// land in a generated file of any size, and this is one line of preview.
    @MainActor
    private func preview(of location: LSP.Location, isHere: Bool) -> String? {
        let line = location.range.start.line
        if isHere, let view = controller?.textView {
            guard let found = view.layoutManager.textLineForIndex(line) else { return nil }
            return (view.textStorage.string as NSString)
                .substring(with: found.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let url = location.fileURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 2_000_000,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard line < lines.count else { return nil }
        return lines[line].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Completions

/// The list, its window and its keyboard are the package's. What it asks of the
/// app is what to put in it, and what to do when one is chosen.
extension LanguageServerCoordinator: CodeSuggestionDelegate {
    /// Characters that open the list without ⌃Space. The common ones across the
    /// languages here rather than the server's own set — the server is asked for
    /// its trigger characters during `initialize`, which is a capability we do
    /// not read back yet.
    ///
    /// **One keystroke each.** `SuggestionTriggerCharacterModel` matches with
    /// `contains(String(lastChar))` against the single character just typed, so a
    /// sequence never matches: Rust's `->` has to be spelled as the `>` that ends
    /// it, and `<` is already here for the same reason on the other side.
    ///
    /// **And it lives on the configuration, not here.** The protocol declares
    /// `completionTriggerCharacters()` but CodeEditSourceEditor 0.15.2 never calls
    /// it — the model reads `peripherals.codeSuggestionTriggerCharacters` instead,
    /// which is why `CodeEditorView` passes this set there. The method below
    /// answers with the same constant so the two cannot drift if a later version
    /// starts asking.
    static let triggerCharacters: Set<String> = [".", ":", ">", "@", "<"]

    func completionTriggerCharacters() -> Set<String> { Self.triggerCharacters }

    @MainActor
    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard isRunning, let service, let view = controller?.textView else { return nil }

        let caret = cursorPosition.range.location
        guard let caretPosition = position(of: caret, in: view) else { return nil }

        let items = await service.completions(uri: uri, position: caretPosition)
        guard isRunning, !items.isEmpty else { return nil }

        // Where the word being completed starts, which is both what the list
        // filters on and where its window belongs.
        let origin = wordStart(before: caret, in: view)
        suggestions = items
        suggestionOrigin = origin

        guard let windowPosition = position(of: origin, in: view) else { return nil }
        return (
            CursorPosition(line: windowPosition.line + 1, column: windowPosition.character + 1),
            filtered(items, prefix: prefix(from: origin, to: caret, in: view)).map(CompletionEntry.init)
        )
    }

    /// Filtering only, no request: the package calls this on every cursor move
    /// while the list is open, and a round trip per keystroke is what makes a
    /// completion list feel broken.
    @MainActor
    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        guard let origin = suggestionOrigin, let view = controller?.textView else { return nil }
        let caret = cursorPosition.range.location
        // Moved off the word being completed — the list no longer describes
        // where the caret is.
        guard caret >= origin else { return nil }
        return filtered(suggestions, prefix: prefix(from: origin, to: caret, in: view))
            .map(CompletionEntry.init)
    }

    @MainActor
    func completionWindowDidClose() {
        suggestions = []
        suggestionOrigin = nil
    }

    @MainActor
    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        guard let entry = item as? CompletionEntry,
              let view = controller?.textView else { return }

        // A `CursorPosition` built from line and column carries no range — it
        // reads as `NSNotFound` until the controller fills it in — so the text
        // view's own selection is the reliable answer.
        let offered = cursorPosition?.range.location
        let caret = (offered == nil || offered == NSNotFound)
            ? view.selectedRange().location
            : offered!
        // The server's own edit range where it gave one — it knows things the
        // editor cannot guess, such as that `foo.ba|` should become `foo.bar`
        // and not `foo.bafoo.bar`. Failing that, the word under the caret.
        let target: NSRange
        if let edit = entry.item.editRange,
           let start = offset(of: edit.start, in: view),
           let end = offset(of: edit.end, in: view),
           start <= end {
            target = NSRange(location: start, length: end - start)
        } else {
            let start = wordStart(before: caret, in: view)
            target = NSRange(location: start, length: caret - start)
        }

        view.replaceCharacters(in: target, with: entry.item.text)
    }

    // MARK: Word under the caret

    /// Where the identifier the caret sits in began.
    ///
    /// Walked back over the line's own text, never the document's: the line is
    /// bounded, and this runs on every keystroke while the list is open.
    @MainActor
    private func wordStart(before caret: Int, in view: TextView) -> Int {
        guard let line = view.layoutManager.textLineForOffset(caret) else { return caret }
        let text = view.textStorage.string as NSString
        var start = caret
        while start > line.range.location {
            let character = text.character(at: start - 1)
            guard let scalar = Unicode.Scalar(character),
                  CharacterSet.alphanumerics.contains(scalar) || character == UInt16(0x5F) else { break }
            start -= 1
        }
        return start
    }

    @MainActor
    private func prefix(from origin: Int, to caret: Int, in view: TextView) -> String {
        guard caret > origin, caret <= view.textStorage.length else { return "" }
        return (view.textStorage.string as NSString)
            .substring(with: NSRange(location: origin, length: caret - origin))
    }

    /// Case-insensitive prefix match on whichever text the server said to filter
    /// on. Not fuzzy: the ordering the server sent is a considered one, and
    /// re-ranking it here would throw that away.
    private func filtered(_ items: [LSP.CompletionItem], prefix: String) -> [LSP.CompletionItem] {
        guard !prefix.isEmpty else { return items }
        let needle = prefix.lowercased()
        return items.filter { ($0.filterText ?? $0.label).lowercased().hasPrefix(needle) }
    }
}

/// One row in the completion list.
///
/// A wrapper rather than a conformance on ``LSP/CompletionItem`` itself: the
/// protocol wants SwiftUI's `Image` and `Color`, and the protocol slice has no
/// business knowing about either.
private struct CompletionEntry: CodeSuggestionEntry {
    let item: LSP.CompletionItem

    var label: String { item.label }
    var detail: String? { item.detail }
    var documentation: String? { nil }
    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    var sourcePreview: String? { nil }
    var deprecated: Bool { false }

    var image: Image {
        switch item.kindLabel {
        case "func", "init": Image(systemName: "function")
        case "class", "struct": Image(systemName: "c.square")
        case "protocol": Image(systemName: "p.square")
        case "enum": Image(systemName: "e.square")
        case "var", "const", "property", "field": Image(systemName: "v.square")
        case "module": Image(systemName: "shippingbox")
        case "keyword": Image(systemName: "k.square")
        case "snippet": Image(systemName: "note.text")
        case "type": Image(systemName: "t.square")
        default: Image(systemName: "circle")
        }
    }

    var imageColor: Color { Color(NSColor.secondaryLabelColor) }
}
