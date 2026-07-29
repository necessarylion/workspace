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
    static var itemChange: Animation { .easeOut(duration: duration) }

    /// A change *within* what is already on screen — a pull request's tabs, a
    /// file picked out of a diff's index. Quicker, and with no rise to it: the
    /// page did not arrive, its middle changed, and the bars around it never
    /// moved to say otherwise.
    static var contentChange: Animation { .easeOut(duration: duration * 0.75) }

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
    /// The outgoing side is deliberately instant. These live in a row beside
    /// other things rather than stacked over them, so two of them alive at once
    /// would be two of them laid out at once — the width of everything beside
    /// them would jump for the length of the fade. One at a time, fading up
    /// from the pane's own colour, costs nothing and moves nothing.
    static var contentArrival: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .identity)
    }
}
