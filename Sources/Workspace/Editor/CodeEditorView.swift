import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

/// The editor pane: a thin wrapper around `SourceEditor` from
/// CodeEditSourceEditor.
///
/// The editor used to be ours — an `NSTextView` subclass on TextKit 1, a
/// hand-written gutter, our own tree-sitter highlighter and an LSP conversation
/// wired to text offsets. All of that is gone; the package is used with its own
/// defaults, so highlighting, the gutter, find and replace, bracket matching and
/// the minimap are its business now.
///
/// What is left here is only the join to the app: the document's text, the
/// caret position it shows in the status bar, and the requests it makes to
/// reload or scroll somewhere.
struct CodeEditorView: View {
    let document: OpenDocument
    var wrapsLines: Bool
    /// The font, line spacing and colours from Settings. Passed in rather than
    /// read here, so the pane above decides when they change.
    var theme: SyntaxTheme

    @State private var state = SourceEditorState()
    /// Held rather than made in `body`: a coordinator is handed over by
    /// reference and has to outlive the render that passed it.
    @State private var clipping = ClipFloatingSubviews()

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
            coordinators: [clipping]
        )
        // A different file in the same pane is a different editor: the package
        // keeps cursor and scroll position in `state`, and carrying the last
        // file's over would open this one part-way down at a line that means
        // nothing here.
        //
        // The revision is in the identity as well, and that is the only way it
        // could be. `SourceEditor`'s text binding runs one way — the text view
        // writes to it, and a value written *into* it is never read back — so a
        // file that changed on disk cannot be pushed into the editor at all.
        // Rebuilding it is what reload means here; the cost is that the caret
        // goes back to the top, where it used to be kept.
        .id("\(document.url.absoluteString)#\(document.externalRevision)")
        .onChange(of: state.cursorPositions) { _, positions in
            // `start` is (-1, -1) for a position given as a plain range, which
            // is what the reveal below hands over before the editor has resolved
            // it into a line — the status bar would read "line 0" for a moment.
            guard let caret = positions?.first?.start, caret.line > 0 else { return }
            document.caretLine = caret.line
            document.caretColumn = caret.column
        }
        .onChange(of: document.revealLine) { _, line in
            guard let line else { return }
            // Clearing the request is a state change, so it waits a turn.
            Task { @MainActor in
                document.revealLine = nil
                // The app counts lines from zero, `CursorPosition` from one.
                state.cursorPositions = [CursorPosition(line: line + 1, column: 1)]
            }
        }
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
            peripherals: .init(
                showMinimap: false,
                showFoldingRibbon: !document.isLargeFile
            )
        )
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
