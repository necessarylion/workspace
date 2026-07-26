import AppKit
import SwiftUI

/// The box that opens over a file's name in the tree to rename it.
///
/// AppKit rather than a SwiftUI `TextField`, because all three things it has to
/// do are ones SwiftUI leaves to chance inside a lazily-built row: take the
/// keyboard the moment it appears, select the name **without** its extension,
/// and answer ⏎ and ⎋ itself — with a `TextField`, ⏎ raced the file list's own
/// ⏎ (which opens the box) and the rename never committed.
struct RenameField: NSViewRepresentable {
    /// The name to start from.
    let text: String
    /// Leave the extension out of the initial selection — retyping the name is
    /// what a rename nearly always is. Off for folders, which have no extension
    /// to speak of (`.github` is the whole name).
    var selectsBaseName = true
    /// ⏎ with what was typed.
    let commit: (String) -> Void
    /// ⎋, or the box losing the keyboard: the name stays as it was.
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(commit: commit, cancel: cancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingTextField(string: text)
        field.selectsBaseName = selectsBaseName
        field.delegate = context.coordinator
        // Matches the row's own name text, so renaming does not resize it.
        field.font = .systemFont(ofSize: 13)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        // Nothing else may squeeze it out of the row.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.commit = commit
        context.coordinator.cancel = cancel
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var commit: (String) -> Void
        var cancel: () -> Void
        /// ⏎ closes the box, which ends the editing session and would otherwise
        /// report a cancel straight after the rename it just asked for.
        private var isFinished = false

        init(commit: @escaping (String) -> Void, cancel: @escaping () -> Void) {
            self.commit = commit
            self.cancel = cancel
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finish { self.commit(textView.string) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish { self.cancel() }
                return true
            default:
                return false
            }
        }

        /// Clicking away leaves the name alone. Finder commits here instead, but
        /// a box left open by accident should not rename anything.
        func controlTextDidEndEditing(_ notification: Notification) {
            finish { self.cancel() }
        }

        private func finish(_ action: () -> Void) {
            guard !isFinished else { return }
            isFinished = true
            action()
        }
    }
}

/// Takes the keyboard once, as soon as it is in a window — from the editor if
/// that is where it was — and picks the part of the name worth retyping.
private final class FocusingTextField: NSTextField {
    var selectsBaseName = true
    private var hasTakenFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !hasTakenFocus else { return }
        hasTakenFocus = true
        // A runloop turn later: SwiftUI is still laying the row out, and a
        // first responder set inside that lands nowhere.
        DispatchQueue.main.async { [weak self] in
            guard let self, window.makeFirstResponder(self), let editor = currentEditor() else { return }
            let name = stringValue as NSString
            let base = name.deletingPathExtension as NSString
            let selectable = selectsBaseName && base.length > 0 && base.length < name.length
            editor.selectedRange = NSRange(location: 0, length: selectable ? base.length : name.length)
        }
    }
}
