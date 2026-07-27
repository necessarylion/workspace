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
    /// most of the app: there ⎋ closes what is open, the same as the ✕ in the
    /// header row.
    ///
    /// Three things keep ⎋ instead.
    ///
    /// A **focused terminal**, because ⎋ is a key the program in it reads. It
    /// is `claude` that makes this matter: ⎋ interrupts a turn, clears the line
    /// and — pressed twice — opens the history, and a turn you cannot call off
    /// is a bad trade for a way of closing the pane that ⌃` and ⇧⌘W both
    /// already offer. It only applies while the shell actually has the
    /// keyboard: click the navigator beside it and ⎋ is the app's again.
    ///
    /// A **completion list** in the editor: dismissing it is the only way out
    /// of a suggestion you did not want, and closing the file instead would be
    /// a poor trade too. And a **box you are writing in** — a comment, a reply,
    /// a commit message, a search field — where ⎋ cancels what was typed, which
    /// is what every other Mac app does with it.
    ///
    /// Selectable-but-not-editable text is why this asks what a text view is
    /// for rather than what class it is: a diff line, a commit message and a
    /// rendered comment are all backed by a read-only text view, and clicking
    /// one used to leave ⎋ doing nothing for the rest of that screen.
    static func leavesEscapeAlone(_ responder: NSResponder?) -> Bool {
        switch responder {
        case is GhosttySurfaceView: false
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
