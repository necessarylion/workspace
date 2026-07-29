import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI

/// The editor pane: a thin wrapper around `SourceEditor` from
/// CodeEditSourceEditor.
///
/// The editor used to be ours — an `NSTextView` subclass on TextKit 1, a
/// hand-written gutter and our own tree-sitter highlighter. All of that is gone;
/// the package is used with its own defaults, so highlighting, the gutter, find
/// and replace, bracket matching and the minimap are its business now.
///
/// What is left here is the join to the app: the document's text, the caret
/// position it shows in the status bar, the requests it makes to reload or scroll
/// somewhere, and the language server — see ``LanguageServerCoordinator``.
struct CodeEditorView: View {
    let document: OpenDocument
    var wrapsLines: Bool
    /// The font, line spacing and colours from Settings. Passed in rather than
    /// read here, so the pane above decides when they change.
    var theme: SyntaxTheme

    @Environment(WorkspaceStore.self) private var store

    /// The identity is on this wrapper rather than on the editor inside it, and
    /// that placement is load-bearing.
    ///
    /// A different file in the same pane is a different editor: the package keeps
    /// cursor and scroll position in its state, and carrying the last file's over
    /// would open this one part-way down at a line that means nothing here. Put
    /// here, the change also resets the `@State` below — which is what keeps a
    /// language server conversation from outliving the file it was about.
    ///
    /// **A file changing on disk is not one of those**, though the revision used
    /// to be in here too. `SourceEditor`'s text binding runs one way — the text
    /// view writes to it, and a value written *into* it is never read back — so
    /// rebuilding looked like the only way to show text that had changed
    /// underneath. It cost the reader their place in the file every time, which
    /// is the wrong trade when the thing writing the file is an agent working
    /// while they read. ``ReloadTextInPlace`` goes to the controller instead, and
    /// the editor now survives a reload.
    ///
    /// What is still here is `isLargeFile`, and only because it can turn over. A
    /// file that grows past the threshold while open wants a different editor
    /// altogether — no highlighting, no language server, wrapping forced on, not
    /// editable — and none of that can be swapped underneath a live one. It is
    /// rare enough to be worth a rebuild, and a rebuild is exactly right when it
    /// happens.
    var body: some View {
        EditorPane(
            document: document,
            wrapsLines: wrapsLines,
            theme: theme,
            store: store
        )
        .id("\(document.url.absoluteString)#\(document.isLargeFile)")
    }
}

private struct EditorPane: View {
    let document: OpenDocument
    var wrapsLines: Bool
    var theme: SyntaxTheme
    /// Held only to be observed: see the `gitRevision` change below. Nil for a
    /// file opened from outside every added repository.
    let project: Project?

    @State private var state = SourceEditorState()
    /// Held rather than made in `body`: a coordinator is handed over by
    /// reference and has to outlive the render that passed it.
    @State private var clipping = ClipFloatingSubviews()
    @State private var finding = ScrollToFindMatch()
    @State private var revealing: RevealPendingPosition
    @State private var reloading: ReloadTextInPlace
    @State private var gitMarkers: GutterDiffMarkers?
    @State private var languageServer: LanguageServerCoordinator?

    init(document: OpenDocument, wrapsLines: Bool, theme: SyntaxTheme, store: WorkspaceStore) {
        self.document = document
        self.wrapsLines = wrapsLines
        self.theme = theme
        _revealing = State(initialValue: RevealPendingPosition(document: document))
        _reloading = State(initialValue: ReloadTextInPlace(document: document))
        // A file outside every added repository has no root to start a server
        // in, and a large one is deliberately left alone.
        let project = store.project(containing: document.url)
        self.project = project
        let root = project?.url
        _languageServer = State(
            initialValue: document.isLargeFile ? nil : root.map {
                LanguageServerCoordinator(document: document, root: $0, store: store)
            }
        )
        // Same two conditions, for the same two reasons: no repository, no diff to
        // draw; and a large file is one the stack only shows.
        _gitMarkers = State(
            initialValue: document.isLargeFile ? nil : root.map {
                GutterDiffMarkers(file: document.url, projectRoot: $0)
            }
        )
    }

    var body: some View {
        SourceEditor(
            Binding(
                get: { document.text },
                set: { document.applyEditorText($0) }
            ),
            // Plain text for a file the stack should only show, so no grammar is
            // loaded and nothing is parsed even if a provider appears.
            language: document.isLargeFile ? .default : CodeLanguage.forFile(url: document.url),
            configuration: configuration,
            state: $state,
            // Empty, not nil. Nil is "use the default", and the default is a
            // `TreeSitterClient` — which is how a 3.5 MB minified bundle came to
            // be parsed after all, while the status bar said highlighting was
            // off. An empty array is how the package is told to colour nothing.
            highlightProviders: document.isLargeFile ? [] : nil,
            coordinators: coordinators,
            completionDelegate: languageServer,
            jumpToDefinitionDelegate: languageServer
        )
        .onChange(of: state.cursorPositions) { _, positions in
            // `start` is (-1, -1) for a position given as a plain range, which
            // is what the reveal below hands over before the editor has resolved
            // it into a line — the status bar would read "line 0" for a moment.
            guard let caret = positions?.first?.start, caret.line > 0 else { return }
            document.caretLine = caret.line
            document.caretColumn = caret.column
        }
        // Only for a file that is *already* open when something asks to reveal a
        // line in it. The first reveal of a newly opened file arrives before this
        // view exists, and `RevealPendingPosition` picks that one up as the
        // controller appears.
        .onChange(of: document.revealLine) { _, line in
            guard line != nil else { return }
            revealing.apply()
        }
        // The file was replaced under the reader — an agent halfway through a
        // refactor, a save from another editor, a branch switched out from under
        // it. Two things follow, and neither is implied by the other: the text
        // goes into the editor that is already showing it, and the markers are
        // asked for again, because the working tree they describe has just moved.
        //
        // The markers used to need no asking. `externalRevision` was in the
        // editor's identity, so the whole pane was rebuilt and this coordinator
        // loaded from scratch as it appeared; now that the editor survives the
        // reload, nothing would tell it.
        .onChange(of: document.externalRevision) { _, _ in
            reloading.apply()
            gitMarkers?.refresh()
        }
        // The same move made by this app rather than to it. ⌘S leaves the editor's
        // text exactly as it is — there is nothing to reload — but it is still the
        // moment the working tree stops matching what git last saw.
        .onChange(of: document.saveRevision) { _, _ in
            gitMarkers?.refresh()
        }
        // And the side the file cannot see at all. The markers are the working tree
        // against HEAD, and a commit or a branch switch moves HEAD while every byte
        // of this file stays where it was — so nothing above fires and the markers
        // would go on describing a baseline that is gone. This is not a poll:
        // `gitRevision` only moves when a status read actually happened, and those
        // are themselves driven by the watchers.
        .onChange(of: project?.gitRevision) { _, _ in
            gitMarkers?.refresh()
        }
    }

    /// Spelled out rather than built from a literal: the two have no type in
    /// common but the protocol, and an array literal of them infers the wrong one.
    private var coordinators: [any TextViewCoordinator] {
        var list: [any TextViewCoordinator] = [clipping, finding, revealing, reloading]
        if let gitMarkers { list.append(gitMarkers) }
        if let languageServer { list.append(languageServer) }
        return list
    }

    private var configuration: SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: theme.editorTheme,
                font: theme.font,
                lineHeightMultiple: theme.lineHeightMultiple,
                // A file too big to lay out in full is always wrapped, whatever
                // the window preference says — the width an unwrapped
                // 300,000-character line asks for is what takes the app down.
                wrapLines: document.isLargeFile ? true : wrapsLines
            ),
            behavior: .init(isEditable: !document.isLargeFile),
            // Zero rather than left alone, and this is the one place the package
            // cannot be taken as it comes.
            //
            // The window is `.hiddenTitleBar`, so its content view is full-size.
            // Given no insets of its own the package turns
            // `automaticallyAdjustsContentInsets` on, and AppKit then insets this
            // scroll view for a titlebar it does not sit under — it sits under
            // the app's own header row. That inset is subtracted straight from
            // the gutter's position:
            //
            //     gutterView.frame.origin.y = textView.frame.origin.y
            //                               - scrollView.contentInsets.top
            //
            // which lifts the line numbers and the folding ribbon out of the
            // scroll view and up through the header. The gutter is a floating
            // subview and `NSView` does not clip, so nothing stops it. Naming
            // the insets — all zero — is what turns the auto-adjustment off.
            layout: .init(contentInsets: NSEdgeInsets()),
            // No minimap. The pane is one of three and already narrow, and the
            // scaled-down picture of the file it draws down the right edge costs
            // more width than it gives back.
            //
            // The folding ribbon goes for a large file as well: what it can fold
            // comes from the syntax tree, and there is no tree for one of those —
            // so it is a column of nothing, drawn per line, over a document with
            // a great many of them.
            //
            // The trigger characters belong here and nowhere else: the package
            // declares `completionTriggerCharacters()` on the delegate but never
            // calls it, and `SuggestionTriggerCharacterModel` reads this instead —
            // so a set given only to the delegate is a set that never fires. Only
            // when there is a server to answer, since the list has nothing to
            // show without one.
            peripherals: .init(
                showMinimap: false,
                showFoldingRibbon: !document.isLargeFile,
                codeSuggestionTriggerCharacters: languageServer == nil
                    ? []
                    : LanguageServerCoordinator.triggerCharacters
            )
        )
    }
}

/// Puts the caret where the document is asking for, and brings it on screen.
///
/// Both halves of that are the reason this exists, because the state binding does
/// neither reliably.
///
/// **It cannot scroll.** `SourceEditor` applies `state.cursorPositions` with
/// `controller.setCursorPositions(cursorPositions)` and no `scrollToVisible:`,
/// which defaults to `false` — so the caret moves to the right line and the
/// viewport stays where it was, leaving the user to scroll to the definition they
/// just asked to be taken to. Its update branch is dead in any case: the
/// condition reads `cursorPositions != state.cursorPositions`, comparing the
/// value it just unwrapped against itself.
///
/// **And it is too late for a new file.** `WorkspaceStore.openFile` sets the
/// reveal on a document it has just built, so for a file that was not already
/// open the value is there from the first render and never changes — nothing for
/// `onChange` to observe.
///
/// So both paths come here instead and go straight to the controller.
private final class RevealPendingPosition: TextViewCoordinator, @unchecked Sendable {
    private let document: OpenDocument
    private weak var controller: TextViewController?

    init(document: OpenDocument) {
        self.document = document
    }

    func prepareCoordinator(controller: TextViewController) {
        MainActor.assumeIsolated { self.controller = controller }
    }

    /// The first reveal of a file that has only just been opened.
    func controllerDidAppear(controller: TextViewController) {
        MainActor.assumeIsolated {
            self.controller = controller
            apply()
        }
    }

    func destroy() {
        MainActor.assumeIsolated { controller = nil }
    }

    /// Deferred a turn: taking the request while the change that made it is still
    /// being delivered would be a mutation inside an observation.
    @MainActor
    func apply() {
        Task { @MainActor [weak self] in
            guard let self,
                  let controller = self.controller,
                  let reveal = self.document.takePendingReveal() else { return }

            let position = CursorPosition(line: reveal.line, column: reveal.column)
            controller.setCursorPositions([position])

            // Scrolled explicitly, rather than by asking `setCursorPositions` to
            // do it with `scrollToVisible:`. That route calls
            // `scrollSelectionToVisible()`, which cannot get started from a cold
            // layout: it opens with `lastFrame = .zero` and loops
            // `while lastFrame != boundingRect`, so a selection whose rect is
            // still `.zero` — which is what an unlaid-out line off the bottom of
            // a file just opened has — fails the condition on the first test and
            // it scrolls nowhere. That is the whole of "the caret is on the right
            // line but the view never moved".
            //
            // `scrollToRange` asks the layout manager for the offset's rect
            // instead, which lays the line out to answer, and stabilises in a loop
            // with a timeout. It centres the line too, which is what a jump to a
            // definition wants — the lines above it are usually the context.
            if let resolved = controller.resolveCursorPosition(position) {
                controller.textView.scrollToRange(resolved.range)
            }
        }
    }
}

/// Puts text that changed on disk into the editor already showing it, and leaves
/// the reader where they were.
///
/// The whole point is the second half. An agent editing the repository while
/// someone reads it will touch the file they are looking at, and the old answer —
/// rebuild the editor, see ``CodeEditorView`` — threw them back to the top of the
/// file every time it did. Being a moment out of date is a smaller problem than
/// losing your place.
///
/// `SourceEditor` will not carry the text in. `updateNSViewController` reads the
/// state binding, the language and the configuration and never once looks at the
/// text, so a value written into the binding is dropped on the floor. The
/// controller does have `setText`, though, and reaching the controller the SwiftUI
/// view built is what `TextViewCoordinator` is for.
///
/// **The scroll offset is what is restored, not the caret.** The two are the same
/// thing only for someone who has not scrolled since they last clicked, which is
/// not someone reading. The caret is put back as well, because the status bar
/// shows it and it costs nothing, but it is not what the viewport is aimed at.
///
/// **And the offset is remembered as a line, not as a number of points.**
/// `TextView.setText` swaps in a new `NSTextStorage` and resets the layout
/// manager, which throws away every line height it had measured and rebuilds the
/// document out of estimates. A y of 4,213 points therefore does not mean quite
/// the same thing on the other side of the call. The line index at the top of the
/// viewport does, so that — plus how far into that line the viewport had cut — is
/// what is taken and what the offset is rebuilt from.
private final class ReloadTextInPlace: TextViewCoordinator, @unchecked Sendable {
    private let document: OpenDocument
    /// What the pane around this was built for.
    ///
    /// A file that crosses the large-file threshold while open wants a different
    /// editor, not the same one holding different text, and `CodeEditorView`'s
    /// identity carries `isLargeFile` for exactly that reason. This is the same
    /// fact from the other side: when it turns over, the reload stands down and
    /// lets the rebuild happen rather than feeding a minified bundle to a
    /// tree-sitter parser for one frame on the way past.
    private let wasLargeFile: Bool
    private weak var controller: TextViewController?

    @MainActor
    init(document: OpenDocument) {
        self.document = document
        self.wasLargeFile = document.isLargeFile
    }

    func prepareCoordinator(controller: TextViewController) {
        MainActor.assumeIsolated { self.controller = controller }
    }

    func controllerDidAppear(controller: TextViewController) {
        MainActor.assumeIsolated { self.controller = controller }
    }

    func destroy() {
        MainActor.assumeIsolated { controller = nil }
    }

    /// Deferred a turn, for both of the reasons this file has met before.
    ///
    /// The change is still being delivered: this is called from an `onChange`,
    /// and `setText` ends in a selection-changed notification that the package
    /// turns into a write to `SourceEditorState` — a SwiftUI state write from
    /// inside a view update. And the restore below would rather the text view had
    /// been given its own layout pass at the new document first.
    @MainActor
    func apply() {
        Task { @MainActor [weak self] in
            guard let self,
                  self.document.isLargeFile == self.wasLargeFile,
                  let controller = self.controller,
                  let scrollView = controller.scrollView,
                  let textView = controller.textView else { return }

            let origin = scrollView.contentView.bounds.origin
            let anchor = textView.layoutManager.textLineForPosition(origin.y)
            let anchorLine = anchor?.index
            let intoLine = anchor.map { origin.y - $0.yPos } ?? 0
            let carets = controller.cursorPositions

            controller.setText(self.document.text)

            // Before anything is asked about where things are: the scroll view
            // clamps against the document view's frame, and that frame is still
            // the old file's height until the next layout pass. A file that got
            // shorter would take the viewport with it.
            textView.updateFrameIfNeeded()

            self.restoreCarets(carets, in: controller)
            self.restoreScroll(to: anchorLine, intoLine: intoLine, x: origin.x, in: controller)
        }
    }

    /// The caret, clamped rather than dropped.
    ///
    /// `setText` already carries the selection across — `setTextStorage` re-sets
    /// the ranges it was holding — but it does it by handing the old ranges to a
    /// selection manager that *filters* anything outside the new text. So a file
    /// that got shorter loses the caret entirely, which reads in the status bar as
    /// the file having no caret at all. Clamping puts it at the end instead.
    @MainActor
    private func restoreCarets(_ positions: [CursorPosition], in controller: TextViewController) {
        let length = controller.textView.textStorage.length
        let clamped = positions.compactMap { position -> CursorPosition? in
            guard position.range.location != NSNotFound else { return nil }
            let location = min(position.range.location, length)
            return CursorPosition(
                range: NSRange(location: location, length: min(position.range.length, length - location))
            )
        }
        guard !clamped.isEmpty else { return }
        controller.setCursorPositions(clamped)
    }

    /// Back to the line that was at the top of the viewport, and to the same point
    /// within it.
    ///
    /// Two steps, and the first is there to make the second true. Straight after
    /// `setText` the layout manager has measured nothing and every line above the
    /// anchor is standing at an estimated height, so the y it reports for the
    /// anchor is a guess — the cold-layout problem ``RevealPendingPosition``
    /// describes at length, arrived at from a third direction. `scrollToRange` is
    /// the way through it there and here: it asks the layout manager for the
    /// offset's rect and lays lines out until the answer stops moving.
    ///
    /// That leaves the anchor's line flush with the top of the viewport, which is
    /// only right for a reader who had happened to stop scrolling on a line
    /// boundary. The second step asks where the line ended up now that it has
    /// really been laid out, and puts the offset back exactly.
    @MainActor
    private func restoreScroll(to line: Int?, intoLine: CGFloat, x: CGFloat, in controller: TextViewController) {
        guard let line, let textView = controller.textView, let scrollView = controller.scrollView,
              let anchor = textView.layoutManager.textLineForIndex(line) else { return }

        textView.scrollToRange(NSRange(location: anchor.range.location, length: 0), center: false)

        guard let settled = textView.layoutManager.textLineForIndex(line) else { return }
        scrollView.scroll(scrollView.contentView, to: CGPoint(x: x, y: max(settled.yPos + intoLine, 0)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// Makes the editor's scroll view clip, which it does not do on its own.
///
/// The gutter is not inside the clip view — the package attaches it with
/// `addFloatingSubview(_:for:)`, which puts it on the scroll view itself so it
/// can stay put on one axis while the text moves. Nothing clips it there, and
/// `NSView.clipsToBounds` is `false` by default, so the gutter is free to draw
/// outside the scroll view entirely. It is as tall as the whole document:
///
///     gutterView.frame.size.height = textView.frame.height + 10
///     gutterView.frame.origin.y = textView.frame.origin.y - …
///
/// so once the file is scrolled at all, its top edge is above the viewport and
/// the line numbers and folding ribbon carry on up through the app's header row.
///
/// There is no setting for this, and `scrollView` is `public`, so a coordinator
/// is the way in. `TextViewCoordinator` exists for exactly this — reaching the
/// controller the SwiftUI view builds without owning its construction.
/// `TextViewCoordinator` carries no actor of its own, so the conformance cannot
/// be main-actor isolated either. Both calls come from the view controller's own
/// lifecycle, which is the main thread by construction — hence
/// `assumeIsolated` rather than a hop, which would land after the first draw.
private final class ClipFloatingSubviews: TextViewCoordinator {
    func prepareCoordinator(controller: TextViewController) {
        MainActor.assumeIsolated { controller.scrollView?.clipsToBounds = true }
    }

    /// Again once the views are really on screen: `prepareCoordinator` runs
    /// while the controller is still being built, and `loadView` replaces the
    /// scroll view wholesale afterwards.
    func controllerDidAppear(controller: TextViewController) {
        MainActor.assumeIsolated { controller.scrollView?.clipsToBounds = true }
    }
}

/// Brings the find panel's current match on screen.
///
/// Cmd+F, a query, Enter — and the selection moves to the next match while the
/// viewport does not, so the match the user asked for is somewhere they cannot
/// see. It is the same failure `RevealPendingPosition` works around, arrived at
/// from the other end.
///
/// The package does ask to be scrolled. `EmphasisManager` selects the current
/// match with `setSelectedRanges` and then calls `scrollSelectionToVisible()`,
/// which opens `lastFrame = .zero` and loops `while lastFrame != boundingRect`.
/// A `TextSelection` is built with a `boundingRect` of `.zero` and only ever
/// given a real one while being *drawn* — and a match below the fold is not
/// drawn — so the condition fails on its first test and the body never runs.
/// Deterministic, and the reason it looks like Enter does nothing at all.
///
/// So the scroll is made here instead, through `scrollToRange`, which asks the
/// layout manager for the offset's rect and lays the line out to answer.
///
/// **Which selection change, and how it is told apart, is the whole design.**
/// `textViewDidChangeSelection` is the coordinator protocol's own callback and it
/// arrives for *every* selection — every arrow key the user presses included.
/// Scrolling on all of them would fight the caret and be a worse bug than the one
/// being fixed. The find panel offers nothing more specific: its view model, its
/// notifications and its emphasis group name are all internal to the package.
///
/// What does distinguish a find move is the emphasis behind it. The panel puts one
/// `Emphasis` per match into a group of its own and marks exactly the current one
/// `selectInDocument`, which is what makes `EmphasisManager` set the selection at
/// all — and it appends the group *before* setting it, so by the time this runs
/// the group already names the match. Requiring the document's whole selection to
/// be that one range is then enough: a caret move is an empty range and matches
/// nothing, and a drag that happens to land on the current match exactly is
/// already on screen, where `scrollToRange` returns without moving.
///
/// The group's name is the package's own and cannot be read from outside, so it is
/// spelled out below. If it ever changes upstream the lookup finds nothing and this
/// goes quiet — back to today's behaviour rather than into a wrong one.
private final class ScrollToFindMatch: TextViewCoordinator, @unchecked Sendable {
    /// `EmphasisGroup.find`, which CodeEditSourceEditor keeps to itself.
    private static let findEmphasisGroup = "codeedit.find"

    private weak var controller: TextViewController?

    func prepareCoordinator(controller: TextViewController) {
        MainActor.assumeIsolated { self.controller = controller }
    }

    func controllerDidAppear(controller: TextViewController) {
        MainActor.assumeIsolated { self.controller = controller }
    }

    func destroy() {
        MainActor.assumeIsolated { controller = nil }
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        MainActor.assumeIsolated {
            self.controller = controller
            scrollToCurrentMatch()
        }
    }

    /// Deferred a turn, and for a sharper reason than `RevealPendingPosition`'s.
    /// This callback is delivered from inside `setSelectedRanges`, which the
    /// emphasis manager is part-way through calling, and `scrollToRange` drives
    /// layout passes of its own. Taking the turn lets the package finish placing
    /// the emphasis layers before the lines under them move.
    @MainActor
    private func scrollToCurrentMatch() {
        Task { @MainActor [weak self] in
            guard let textView = self?.controller?.textView,
                  let current = textView.emphasisManager?
                      .getEmphases(for: Self.findEmphasisGroup)
                      .first(where: \.selectInDocument),
                  textView.selectionManager?.textSelections.map(\.range) == [current.range] else { return }

            textView.scrollToRange(current.range)
        }
    }
}
