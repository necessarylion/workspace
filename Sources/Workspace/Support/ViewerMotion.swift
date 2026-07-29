import AppKit
import SwiftUI

/// How the centre pane changes what it is showing.
///
/// Opening a file, opening a pull request, opening a diff and moving between a
/// pull request's tabs are four journeys through the same one pane, so they are
/// written here together and arrive alike. Nothing here decides what is on
/// screen or where it sits — only how it gets there.
///
/// The register is deliberately small. This is a window on a Mac, not a phone:
/// a change of screen should read as the pane settling rather than as something
/// sliding across it, so the whole vocabulary is a fade, a sixth of a second,
/// and at most a few points of rise. `WorkspaceStore.chatPanelMotion` is the
/// same idea for the panels that float over the window; this is the centre.
@MainActor
enum ViewerMotion {
    /// The one duration. Everything below is this or a fraction of it, so a
    /// change here retimes all four places at once.
    static let duration: TimeInterval = 0.16

    /// Whether the person at the keyboard has asked for less movement.
    ///
    /// Read each time rather than kept: the setting can be turned on while the
    /// app is running, and the next thing drawn should already obey it.
    static var isReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Replacing the whole item in the viewer — a file for a diff, a diff for a
    /// pull request. Ease-out rather than ease-in-out: the click already
    /// happened, so the movement should be quickest at the start and then come
    /// to rest.
    ///
    /// **Unconditional, where the tokens below go nil under Reduce Motion.**
    /// This one and ``contentChange`` only ever time a fade: what travels is
    /// decided by ``itemArrival(isTerminal:)``, which drops the rise and leaves
    /// a cross-fade. Asking for less movement is not asking for none, and a
    /// fade is what the setting wants in place of travel rather than something
    /// to be switched off. Anything hung off these two that *does* move must
    /// take its own guard.
    static var itemChange: Animation { .easeOut(duration: duration) }

    /// A change *within* what is already on screen — a pull request's tabs, a
    /// file picked out of a diff's index. Quicker, and with no rise to it: the
    /// page did not arrive, its middle changed, and the bars around it never
    /// moved to say otherwise.
    static var contentChange: Animation { .easeOut(duration: duration * 0.75) }

    /// A pane folding away or coming back — the repositories rail, the
    /// navigator. Its *presence*, never its width: three separate things in
    /// this window turn a pane's size into work, and a terminal reflows its
    /// whole grid on every one it is handed.
    static var paneChange: Animation? { isReduced ? nil : .easeOut(duration: 0.18) }

    /// Rows arriving in or leaving a list — a terminal opened, a repository
    /// added, a pull request merged somewhere else. Ease-in-out rather than
    /// ease-out: nothing was clicked to cause most of these, so there is no
    /// moment for the movement to be quickest at.
    static var listChange: Animation? { isReduced ? nil : .easeInOut(duration: duration) }

    /// A twisty turning, and what it reveals. The shortest of them: a
    /// disclosure that takes its time reads as the app thinking about it.
    static var disclosure: Animation? { isReduced ? nil : .easeInOut(duration: 0.15) }

    /// A count changing or a badge appearing. The longest, because these are
    /// small and off to one side — too quick and the eye never catches that
    /// anything happened, which is the whole reason to animate a number.
    static var badgeChange: Animation? { isReduced ? nil : .easeOut(duration: 0.2) }

    /// How a new viewer item comes in, and how the one it replaces goes.
    ///
    /// The two are not the same. What arrives fades up from a few points below,
    /// which is the whole of the "it came from somewhere" reading; what leaves
    /// only fades, because a thing moving *and* a thing moving away is two
    /// motions where the eye wanted one. Under Reduce Motion nothing travels at
    /// all and the two cross-fade.
    ///
    /// A terminal gets none of it. `GhosttySurfaceView` is a live grid that
    /// reflows on every size it is handed and redraws whatever `claude` has
    /// written into it; the offset here would not resize it, but the shell is
    /// the one thing in the window that is mid-sentence, and the honest
    /// treatment of it is to leave it alone.
    static func itemArrival(isTerminal: Bool) -> AnyTransition {
        if isTerminal { return .identity }
        if isReduced { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)),
            removal: .opacity
        )
    }

    /// How a tab or a picked file comes in, where the frame around it stays
    /// put.
    ///
    /// Both sides fade. The removal was `.identity` at first, on the reading
    /// that it meant "gone at once" — it does not. It means *drawn unchanged*,
    /// so the tab being left sat at full strength underneath for the whole of
    /// the fade and the arriving one came up through it: two lists of text over
    /// one another, which is what a reader sees as the app showing them the
    /// wrong page. Neither side was ever cheaper for it, since both are alive
    /// and laid out either way; the only thing `.identity` bought was the
    /// ghost.
    static var contentArrival: AnyTransition { .opacity }
}
