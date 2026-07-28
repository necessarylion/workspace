import AppKit
import SwiftUI

/// A key the file tree answers.
enum FileTreeKey {
    case rename
    case trash
    /// ⌘C: puts the selected files on the pasteboard as files, so Finder and
    /// every other app that takes them can paste them.
    case copy
    /// ⌘V: puts whatever files are on the pasteboard into the picked folder —
    /// the other half of a ⌘C in Finder.
    case paste
    /// ↑ / ↓, with ⇧ held to stretch the selection instead of moving it.
    case move(by: Int, extending: Bool)
}

/// Zero-sized view that holds the keyboard for the file tree.
///
/// SwiftUI's own focus was not enough here. Clicking a row opens the file, and
/// the editor makes its text view first responder as it appears — so the first
/// ⌘⌫ after a click went to the editor and only the next one reached the tree,
/// once a redraw had put SwiftUI's focus back. An `NSView` that we hand the
/// keyboard to explicitly settles it: after a click the tree **is** the first
/// responder, and clicking the editor or the terminal takes it back the ordinary
/// way, so no key is ever answered by two things at once.
struct FileTreeKeyCatcher: NSViewRepresentable {
    /// Raised by the list every time it should take the keyboard — a row was
    /// clicked, or the rename box closed. The value itself means nothing; only
    /// that it changed.
    let claims: Int
    /// Returns true when the key was used, false to let it carry on.
    let handle: (FileTreeKey) -> Bool
    /// Whether the key would do anything at all, asked without doing it — the
    /// Edit menu wants to know before it draws Copy and Paste enabled.
    let canHandle: (FileTreeKey) -> Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handle = handle
        view.canHandle = canHandle
        view.claims = claims
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.handle = handle
        view.canHandle = canHandle
        guard view.claims != claims else { return }
        view.claims = claims
        // A runloop turn later: taking the keyboard in the middle of a SwiftUI
        // update lands nowhere, and the rename box may still be closing.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    final class KeyView: NSView, NSMenuItemValidation {
        var handle: (FileTreeKey) -> Bool = { _ in false }
        var canHandle: (FileTreeKey) -> Bool = { _ in false }
        var claims = 0

        override var acceptsFirstResponder: Bool { true }
        /// Not part of the ⇥ loop: the tree is reached by clicking it.
        override var canBecomeKeyView: Bool { false }

        override func keyDown(with event: NSEvent) {
            guard let key = Self.key(for: event), handle(key) else {
                super.keyDown(with: event)
                return
            }
        }

        // MARK: Copy and paste
        //
        // ⌘C and ⌘V are the Edit menu's, and a menu key equivalent is answered
        // before `keyDown` ever runs — so these two arrive as the selectors the
        // menu sends down the responder chain rather than as a key press. The
        // tree is the first responder while it has the keyboard, which is what
        // puts both the keys *and* the menu items on it. `key(for:)` still
        // knows them, for the case where the menu did not take the event.

        @objc func copy(_ sender: Any?) {
            _ = handle(.copy)
        }

        @objc func paste(_ sender: Any?) {
            _ = handle(.paste)
        }

        /// Greys the two items out when there is nothing selected to copy, or
        /// nothing on the pasteboard to put down.
        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            switch menuItem.action {
            case #selector(copy(_:)): return canHandle(.copy)
            case #selector(paste(_:)): return canHandle(.paste)
            default: return true
            }
        }

        /// Read off the raw event: key codes are the same on every layout, and
        /// they say plainly which key was hit even with ⌘ held.
        private static func key(for event: NSEvent) -> FileTreeKey? {
            // Caps lock and the function flag some keyboards set are not a
            // different key, so only the four that matter get a say.
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch event.keyCode {
            case 36, 76:  // ⏎ and the keypad's ⏎
                return modifiers.isEmpty ? .rename : nil
            case 51:  // ⌫
                return modifiers == .command ? .trash : nil
            // Only reached when the Edit menu did not answer ⌘C / ⌘V first —
            // it is disabled, or the app is running without those items. The
            // handler refuses the same cases `validateMenuItem` greys out, so
            // this cannot do what the menu had just said could not be done.
            case 8:  // C
                return modifiers == .command ? .copy : nil
            case 9:  // V
                return modifiers == .command ? .paste : nil
            case 126:  // ↑
                return modifiers.subtracting(.shift).isEmpty
                    ? .move(by: -1, extending: modifiers.contains(.shift)) : nil
            case 125:  // ↓
                return modifiers.subtracting(.shift).isEmpty
                    ? .move(by: 1, extending: modifiers.contains(.shift)) : nil
            default:
                return nil
            }
        }
    }
}
