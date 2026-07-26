import AppKit
import SwiftUI

/// The box a prompt is typed in: **one line tall to start with**, growing a
/// line at a time as the text needs them, and scrolling once it reaches its
/// limit rather than eating the window.
///
/// AppKit rather than a `TextEditor`, for the same reason ``RenameField`` is:
/// a `TextEditor` is a fixed height whatever is in it, and the two keys that
/// matter here cannot be told apart above it — ⏎ sends, ⇧⏎ writes a line, and
/// both arrive as the same `insertNewline:`, so it takes a text view to ask
/// which one was actually pressed.
/// A key the completion list wants first, when one is open.
enum ChatCompletionKey {
    case up, down, accept, dismiss
}

struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    /// How tall the box wants to be. The caller puts it in a `frame`, so the
    /// growing is something SwiftUI lays out rather than something AppKit does
    /// behind its back.
    @Binding var height: CGFloat
    /// Where the caret is, as a UTF-16 offset. Two-way: the field reports it as
    /// you type, and setting it moves the caret — which is what puts it after a
    /// completion that has just been inserted.
    @Binding var caret: Int

    var placeholder = ""
    /// How far it grows before it starts scrolling instead.
    var maxLines = 10
    var onSubmit: () -> Void
    var onEscape: () -> Void
    /// Offered ↑ ↓ ⏎ ⇥ ⎋ before the field acts on them. Returning true means a
    /// completion list took the key, so the field leaves it alone.
    var onCompletionKey: (ChatCompletionKey) -> Bool = { _ in false }

    /// The height of an empty box, so the caller can start there.
    static var singleLineHeight: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        return ceil(NSLayoutManager().defaultLineHeight(for: font)) + verticalInset * 2
    }

    private static let verticalInset: CGFloat = 3
    private static let horizontalInset: CGFloat = 2

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = ChatTextView()
        textView.delegate = context.coordinator
        textView.placeholder = placeholder
        textView.string = text
        textView.font = NSFont.preferredFont(forTextStyle: .callout)
        textView.textColor = .labelColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(
            width: Self.horizontalInset,
            height: Self.verticalInset
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        // A chat pane is opened in order to type in it.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ChatTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
        // Only once the text agrees, or the caret would be placed in a string
        // the view has not been given yet — which is exactly the moment a
        // completion is inserted.
        let wanted = min(max(caret, 0), textView.string.utf16.count)
        if textView.string == text, textView.selectedRange().location != wanted {
            textView.setSelectedRange(NSRange(location: wanted, length: 0))
        }
        textView.placeholder = placeholder
        // Never straight from `updateNSView`: the height is state SwiftUI is in
        // the middle of reading.
        DispatchQueue.main.async {
            context.coordinator.reportHeight(of: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputField

        init(parent: ChatInputField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? ChatTextView else { return }
            parent.text = textView.string
            parent.caret = textView.selectedRange().location
            // The placeholder is drawn by the text view itself, so it has to be
            // told the string went from empty to not.
            textView.needsDisplay = true
            reportHeight(of: textView)
        }

        /// What the completion list watches: which `@` or `/` the caret is
        /// sitting in depends on where it is, not only on what was typed —
        /// clicking away from a half-written mention has to close the list.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let location = textView.selectedRange().location
            guard parent.caret != location else { return }
            parent.caret = location
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onCompletionKey(.up)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onCompletionKey(.down)
            case #selector(NSResponder.insertTab(_:)):
                return parent.onCompletionKey(.accept)
            case #selector(NSResponder.insertNewline(_:)):
                // A list that is up owns ⏎: it is picking the completion, not
                // sending a half-typed mention.
                if parent.onCompletionKey(.accept) { return true }
                // Both keys arrive here; only the event knows which was pressed.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // ⎋ closes the list first, and only closes the chat once there
                // is no list left to close.
                if parent.onCompletionKey(.dismiss) { return true }
                parent.onEscape()
                return true
            default:
                return false
            }
        }

        func reportHeight(of textView: NSTextView) {
            let measured = height(of: textView)
            guard abs(measured - parent.height) > 0.5 else { return }
            parent.height = measured
        }

        /// What the text actually needs, floored at one line and capped at
        /// `maxLines` — past that the box stops growing and scrolls.
        private func height(of textView: NSTextView) -> CGFloat {
            guard let container = textView.textContainer,
                  let manager = textView.layoutManager else { return parent.height }
            manager.ensureLayout(for: container)

            let font = textView.font ?? NSFont.preferredFont(forTextStyle: .callout)
            let line = manager.defaultLineHeight(for: font)
            let used = manager.usedRect(for: container).height
            let inset = textView.textContainerInset.height * 2
            return ceil(min(max(used, line), line * CGFloat(parent.maxLines))) + inset
        }
    }
}

/// A text view that draws its own placeholder. `NSTextView` has none of its
/// own, and a label laid over the top has to guess the text's origin — the text
/// view already knows it.
private final class ChatTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        placeholder.draw(at: origin, withAttributes: [
            .font: font ?? NSFont.preferredFont(forTextStyle: .callout),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }
}
