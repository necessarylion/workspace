import AppKit
import SwiftUI

extension View {
    /// Runs `action` when ⎋ is pressed in this view's window, unless the key
    /// already belongs to whatever has focus.
    func onEscapeKey(when enabled: Bool = true, perform action: @escaping () -> Void) -> some View {
        onWindowKeyEvent { event, window in
            guard enabled,
                  event.isEscape,
                  // A sheet's own Cancel already answers ⎋.
                  window.attachedSheet == nil,
                  EscapeKey.leavesEscapeAlone(window.firstResponder)
            else { return false }
            action()
            return true
        }
    }
}

enum EscapeKey {
    /// True when the focused responder has no use for ⎋ of its own — which is
    /// nearly everything, the terminal and the editor included: there ⎋ closes
    /// what is open rather than reaching the shell or the text.
    ///
    /// Two things still keep ⎋. A **completion list** in the editor: dismissing
    /// it is the only way out of a suggestion you did not want, and closing the
    /// file instead would be a poor trade. And a **box you are writing in** — a
    /// comment, a reply, a commit message, a search field — where ⎋ cancels
    /// what was typed, which is what every other Mac app does with it.
    ///
    /// Selectable-but-not-editable text is why this asks what a text view is
    /// for rather than what class it is: a diff line, a commit message and a
    /// rendered comment are all backed by a read-only text view, and clicking
    /// one used to leave ⎋ doing nothing for the rest of that screen.
    static func leavesEscapeAlone(_ responder: NSResponder?) -> Bool {
        switch responder {
        case let code as CodeTextView: !code.isShowingCompletions
        case let text as NSTextView: !text.isEditable
        case is NSText: false
        default: true
        }
    }
}

extension NSEvent {
    /// ⎋ on its own. ⌥⎋ and ⌘⎋ are the system's, and ⇧⎋ means nothing here —
    /// but caps lock, and the function flag some keyboards set, are not a
    /// different key, so only the four that are get a say.
    var isEscape: Bool {
        type == .keyDown
            && keyCode == 53
            && modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }
}
