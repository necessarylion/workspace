import AppKit
import SwiftUI

/// Find-in-file: what is being looked for, how many places it turns up, and
/// which of them the caret is on.
///
/// One of these for the whole app rather than one per file, because there is
/// one editor — see `WorkspaceStore.closeOtherFiles(keeping:)`. It holds the
/// controller directly so ⏎ can move the selection there and then: routing a
/// jump through the document as a request the editor notices on its next
/// update makes "press ⏎ four times quickly" a matter of luck.
@MainActor
@Observable
final class EditorFind {
    var isShowing = false
    var query = ""
    /// How many places the query occurs in the file, as the editor counted them.
    var matchCount = 0
    /// Which match the caret is on, counted from 1. Zero until ⏎ is pressed:
    /// typing marks every hit and moves nothing, so there is no "current" one
    /// to name yet.
    var current = 0
    /// Bumped to hand the box the keyboard — ⌘F on a bar that is already up
    /// should put the caret back in it rather than do nothing.
    var focusRequests = 0

    /// Not observed: the editor is a view, and a view being replaced should not
    /// invalidate the bar above it.
    @ObservationIgnored weak var controller: CodeEditorController?

    func open() {
        isShowing = true
        focusRequests += 1
    }

    /// Closes the bar and takes the marks with it — an empty query is what
    /// tells the editor there is nothing to highlight.
    func close() {
        isShowing = false
        query = ""
        current = 0
        matchCount = 0
        controller?.focus()
    }

    /// Moves to the next match after the caret, or the one before it, wrapping
    /// round the end of the file either way.
    func step(forward: Bool) {
        guard let controller, !query.isEmpty else { return }
        current = controller.goToSearchMatch(forward: forward)
    }
}

/// The find bar, floating in the editor's top corner.
///
/// Over the text rather than above it: a bar that pushed the editor down would
/// move every line on screen at the moment you are trying to find one, and the
/// corner it sits in is the one place a line's text almost never reaches.
struct EditorFindBar: View {
    @Bindable var find: EditorFind

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Find", text: $find.query)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 160)
                .focused($isFocused)
                // ⏎ is the whole navigation: type, then press it to walk the
                // file hit by hit.
                .onSubmit { find.step(forward: true) }

            Text(countLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(find.matchCount == 0 && !find.query.isEmpty ? .orange : .secondary)
                // Steady width, so the bar does not twitch as the count changes
                // under the typing.
                .frame(minWidth: 58, alignment: .trailing)

            Divider().frame(height: 14)

            barButton("chevron.up", help: "Previous match") { find.step(forward: false) }
            barButton("chevron.down", help: "Next match (⏎)") { find.step(forward: true) }
            barButton("xmark", help: "Close (⎋)") { find.close() }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary)
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(12)
        .onAppear { isFocused = true }
        .onChange(of: find.focusRequests) { isFocused = true }
        // Every keystroke moves the marks, so the place in the file the last ⏎
        // reached no longer means anything.
        .onChange(of: find.query) { find.current = 0 }
    }

    private var countLabel: String {
        if find.query.isEmpty { return "" }
        if find.matchCount == 0 { return "none" }
        if find.current == 0 { return "\(find.matchCount) found" }
        return "\(find.current) of \(find.matchCount)"
    }

    private func barButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .pointerCursor()
    }
}
