import AppKit
import SwiftUI

extension View {
    /// Stops the window from putting the keyboard in a text field the moment it
    /// opens.
    ///
    /// A window with no `initialFirstResponder` of its own picks one the first
    /// time it becomes key: the first view in the key view loop that will take
    /// the job, which here is the repositories filter. So the app started
    /// *inside* a search box nobody had clicked — typing went into it, and ⎋
    /// belonged to it rather than to the open item, which is why the close key
    /// did nothing until the code editor had taken focus once and handed it
    /// back (see ``EscapeKey``).
    ///
    /// Pointing the window at a view that refuses to be first responder leaves
    /// the responder on the window itself, which is where a window with nothing
    /// open should start.
    func withoutInitialTextFocus() -> some View {
        background(InitialFocusRelease().frame(width: 0, height: 0))
    }
}

private struct InitialFocusRelease: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ReleaseView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Zero-sized, and there only to be the responder the window reaches for and
/// does not get.
private final class ReleaseView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = self
        // SwiftUI may only lay this view out after the window is already key,
        // in which case the choice has been made and claiming it back is the
        // only way out of it. A field editor is the whole of what the window
        // picks on its own, so nothing the user did is being taken here.
        if window.firstResponder is NSText {
            window.makeFirstResponder(nil)
        }
    }
}
