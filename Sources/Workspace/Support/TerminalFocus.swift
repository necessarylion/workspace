import AppKit

/// Everything the app knows about whether the keyboard belongs to a terminal.
///
/// A `GhosttySurfaceView` claims first responder in its own `mouseDown`, so a
/// click landing *in* a conversation already puts the cursor at its prompt. What
/// no view answers for is the two halves either side of that. A click on a
/// panel's title bar, on its edges or on the gaps between its buttons means "I
/// am reading this one" just as surely, and nothing there was taking the keys.
/// And a click on the dashboard, a repository or a file left them where they
/// were, because a SwiftUI row claims no focus of its own — so the window went
/// on typing into a conversation the reader had walked away from.
///
/// These are the moves, not the policy: the one place that decides which of them
/// a click means is ``WindowClickMonitor``, and it is deliberately the only
/// place. Two mechanisms setting first responder in the same turn of the runloop
/// is a coin toss, and what loses it is whatever the user just clicked.
@MainActor
enum TerminalFocus {
    /// Puts the keyboard in this conversation.
    ///
    /// Not while `claude` is still being typed at it: what is behind the cover
    /// then is a shell prompt the app is about to run a command from, and a
    /// keystroke landing there goes into that command rather than into the
    /// conversation. ``TerminalPaneView`` holds the same line for the first
    /// focus a surface ever gets, and for the same reason.
    static func give(to session: TerminalSession) {
        guard !session.isStartingClaude else { return }
        let view = session.view
        guard let window = view.window, window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }

    /// Takes the keyboard out of a conversation that is on its way off screen —
    /// folded down to the dock, or ended. Neither is somewhere the reader can
    /// still see what they are typing, and a hidden terminal quietly receiving
    /// keystrokes is worse than no focus at all.
    static func relinquish(_ session: TerminalSession) {
        let view = session.view
        guard let window = view.window, window.firstResponder === view else { return }
        window.makeFirstResponder(nil)
    }

    /// Hands the keyboard back to nobody, the way ``withoutInitialTextFocus``
    /// leaves a window that has just opened.
    ///
    /// **To nobody, and not to some other view.** This runs from a mouse-down
    /// monitor, which sees the event before it is dispatched — so whatever the
    /// click is actually aimed at claims focus for itself a moment later if it
    /// wants any, and a text field is still a text field to click into. Naming a
    /// successor here would be guessing at that on its behalf.
    ///
    /// Nothing happens unless a terminal is what holds focus. Typing in a filter
    /// box, a rename field or the editor is somebody's sentence in progress.
    static func release(in window: NSWindow) {
        guard isHeldByTerminal(in: window) else { return }
        window.makeFirstResponder(nil)
    }

    /// Whether the keys are going into a terminal right now.
    static func isHeldByTerminal(in window: NSWindow) -> Bool {
        focused(in: window) != nil
    }

    /// The terminal the keys are going into right now, if they are going into
    /// one. What a key meant for a *conversation* — rather than for the window —
    /// is recognised by: the panel it belongs to is the one holding this surface.
    static func focused(in window: NSWindow) -> GhosttySurfaceView? {
        surface(enclosing: window.firstResponder as? NSView)
    }

    /// The terminal a point in the window lands in, if it lands in one.
    ///
    /// Hit-tested rather than measured against the panels' rectangles. Panels
    /// overlap each other, the dock's bars ride over the centre pane, and a
    /// folded conversation is still mounted at its full size behind a crop — a
    /// rectangle knows none of that, and would answer for whichever of the
    /// things drawn in one place it happened to be asked about. The hit test is
    /// the same one AppKit is about to dispatch the click with, so it answers
    /// with what will really get it.
    static func surface(under point: NSPoint, in window: NSWindow) -> GhosttySurfaceView? {
        // `hitTest` takes a point in the receiver's *superview*, which for the
        // content view is the window's own coordinate space.
        surface(enclosing: window.contentView?.hitTest(point))
    }

    /// The terminal a view is part of: itself, or the one it is drawn inside. A
    /// surface has no subviews today, but the walk costs nothing and keeps this
    /// true if it ever grows one.
    private static func surface(enclosing view: NSView?) -> GhosttySurfaceView? {
        var candidate = view
        while let current = candidate {
            if let surface = current as? GhosttySurfaceView { return surface }
            candidate = current.superview
        }
        return nil
    }
}
