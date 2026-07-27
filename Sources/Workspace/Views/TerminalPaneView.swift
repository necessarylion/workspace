import SwiftUI

/// Hosts a running `GhosttySurfaceView`. The view instance lives on the
/// session, so navigating away and back never restarts the shell.
struct TerminalPaneView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> GhosttySurfaceView {
        let view = session.view
        focusWhenReady(view, context.coordinator)
        return view
    }

    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
        // The terminal owns its own state; the one thing left to answer is the
        // cover coming down, which is when a Claude tab first wants the keys.
        focusWhenReady(nsView, context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Focuses the shell as soon as it is on screen — but not while `claude` is
    /// still starting: a keystroke landing then would go into the very prompt
    /// the app is about to type the command at. Once done, it is never repeated,
    /// so an unrelated redraw cannot pull focus out of whatever the user is
    /// typing in elsewhere in the window.
    private func focusWhenReady(_ view: GhosttySurfaceView, _ coordinator: Coordinator) {
        guard !coordinator.hasFocused, !session.isStartingClaude else { return }
        coordinator.hasFocused = true
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }

    final class Coordinator {
        var hasFocused = false
    }
}

/// The terminal item: just the shell that is selected. Switching between a
/// repository's shells happens in the navigator's Terminals tab, so the viewer
/// still shows one thing at a time with no tab bar of its own.
struct TerminalContainerView: View {
    let item: ViewerItem

    var body: some View {
        if let session = item.selectedTerminal {
            // A small inset so the first line doesn't touch the edges.
            TerminalPaneView(session: session)
                .padding(.top, 10)
                .padding(.leading, 6)
                .background(Color(nsColor: AppColors.terminalBackground))
                // A new representable per session: the NSView belongs to the
                // session and cannot be swapped in updateNSView.
                .id(session.id)
                .overlay {
                    if session.isStartingClaude {
                        ClaudeStartupCover().transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: session.isStartingClaude)
        } else {
            ContentUnavailableView("Terminal ended", systemImage: "terminal")
        }
    }
}

/// What a conversation's tab shows until `claude` is up.
///
/// Opaque on purpose: what it hides is the shell spawning and the app typing a
/// command into it, which is the app's business and reads as a glitch. The
/// conversation appears the way it does everywhere else — as one thing that was
/// asked for and then arrived.
private struct ClaudeStartupCover: View {
    var body: some View {
        VStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text("Starting Claude Code…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: AppColors.terminalBackground))
    }
}
