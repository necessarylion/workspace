import AppKit
import SwiftUI

/// A key the file tree answers.
enum FileTreeKey {
    case rename
    case trash
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

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handle = handle
        view.claims = claims
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.handle = handle
        guard view.claims != claims else { return }
        view.claims = claims
        // A runloop turn later: taking the keyboard in the middle of a SwiftUI
        // update lands nowhere, and the rename box may still be closing.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    final class KeyView: NSView {
        var handle: (FileTreeKey) -> Bool = { _ in false }
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
