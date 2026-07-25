import SwiftUI

/// Hosts a running `GhosttySurfaceView`. The view instance lives on the
/// session, so navigating away and back never restarts the shell.
struct TerminalPaneView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> GhosttySurfaceView {
        let view = session.view
        // Focus the shell as soon as it is on screen.
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
        // Nothing to sync: the terminal owns its own state.
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
        } else {
            ContentUnavailableView("Terminal ended", systemImage: "terminal")
        }
    }
}
